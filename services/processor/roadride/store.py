"""Database writes for the live path. The caller owns the transaction (one per Event Hubs batch),
so the rows and the stream checkpoint commit together."""

from __future__ import annotations

import datetime as dt
import logging
from typing import Callable, TypeVar

import numpy as np
from psycopg import Connection
from psycopg.types.json import Jsonb

from . import clock
from .db import is_connection_loss, is_retryable_conflict
from .dsp import Pipeline
from .live import BatchFacts, SessionFacts, exclusion_reasons

log = logging.getLogger(__name__)

T = TypeVar("T")



def from_epoch(seconds: float) -> dt.datetime:
    return dt.datetime.fromtimestamp(seconds, tz=dt.timezone.utc)


class Store:
    def __init__(self, conn: Connection):
        self.conn = conn
        self.ended: list[str] = []  # trips this store moved to `processing` (ready.py sends for them)
        # Optional parts of a batch dropped because they failed (labels, signal, live_state).
        self.dropped: dict[str, int] = {}

    def _optional(self, part: str, session_id: str, fn: Callable[[], T]) -> tuple[bool, T | None]:
        """Runs an optional part of a batch in its own savepoint. If it fails, only that part is
        lost: the batch itself (ingest_batches row, track) still counts, so the trip can complete.
        Connection loss and deadlocks are re-raised: the caller retries those."""
        try:
            with self.conn.transaction():
                return True, fn()
        except Exception as exc:  # noqa: BLE001
            if is_connection_loss(exc, self.conn) or is_retryable_conflict(exc):
                raise
            log.warning("dropping %s of a batch of session %s", part, session_id, exc_info=True)
            self.dropped[part] = self.dropped.get(part, 0) + 1
            return False, None

    # --- checkpoints ---------------------------------------------------------------------

    def load_checkpoints(self, eventhub: str, consumer_group: str) -> dict[str, int]:
        rows = self.conn.execute(
            "SELECT partition_id, sequence_number FROM stream_checkpoints "
            "WHERE eventhub = %s AND consumer_group = %s",
            (eventhub, consumer_group),
        ).fetchall()
        return {pid: seq for pid, seq in rows}

    def load_checkpoint_rows(self, eventhub: str, consumer_group: str
                             ) -> dict[str, tuple[int, dt.datetime]]:
        """partition_id -> (sequence number, when it was saved)."""
        rows = self.conn.execute(
            "SELECT partition_id, sequence_number, updated_at FROM stream_checkpoints "
            "WHERE eventhub = %s AND consumer_group = %s",
            (eventhub, consumer_group),
        ).fetchall()
        return {pid: (seq, updated) for pid, seq, updated in rows}

    def save_checkpoint(self, eventhub: str, consumer_group: str, partition_id: str,
                        sequence_number: int, enqueued_at: dt.datetime | None) -> None:
        self.conn.execute(
            """
            INSERT INTO stream_checkpoints (eventhub, consumer_group, partition_id, sequence_number,
                                            enqueued_at, updated_at)
            VALUES (%s, %s, %s, %s, %s, now())
            ON CONFLICT (eventhub, consumer_group, partition_id) DO UPDATE
              SET sequence_number = EXCLUDED.sequence_number,
                  enqueued_at = EXCLUDED.enqueued_at,
                  updated_at = now()
            """,
            (eventhub, consumer_group, partition_id, sequence_number, enqueued_at),
        )

    # --- shared --------------------------------------------------------------------------

    def _touch_device(self, device_id: str | None) -> None:
        if device_id:
            self.conn.execute(
                "INSERT INTO devices (device_id) VALUES (%s) "
                "ON CONFLICT (device_id) DO UPDATE SET last_seen_at = now()",
                (device_id,),
            )

    def _mark_processing_when_complete(self, session_id: str) -> None:
        """A trip has ended when its Stop copy has arrived and every batch up to batchCount is in
        (plan §5 "Trip end"). ready.py puts "session ready" on the queue once this commits."""
        row = self.conn.execute(
            """
            UPDATE sessions s SET status = 'processing', updated_at = now()
            WHERE s.session_id = %s AND s.status = 'live' AND s.expected_batch_count IS NOT NULL
              AND (SELECT count(*) FROM ingest_batches b
                   WHERE b.session_id = s.session_id AND b.batch_seq < s.expected_batch_count)
                  >= s.expected_batch_count
            RETURNING s.session_id
            """,
            (session_id,),
        ).fetchone()
        if row:
            self.ended.append(row[0])

    def _reopen(self, session_id: str) -> None:
        """A trip that already ended (or was finalized) got new data: a batch from the phone's backlog
        after the 15-minute close, or its Stop copy. Back to `processing` with no message sent, so
        ready.py sends "session ready" again and the finalize job rebuilds it from the archive."""
        self.conn.execute(
            "UPDATE sessions SET status = 'processing', ready_sent_at = NULL, updated_at = now() "
            "WHERE session_id = %s AND status <> 'live'",
            (session_id,),
        )
        self.ended.append(session_id)

    def _refresh_exclusions(self, session_id: str) -> None:
        row = self.conn.execute(
            "SELECT source, status, context_known, mount, quality_status FROM sessions "
            "WHERE session_id = %s",
            (session_id,),
        ).fetchone()
        if row is None:
            return
        source, status, context_known, mount, quality = row
        reasons = exclusion_reasons(source, status, context_known, mount, quality)
        # not_rigid / handheld only exclude a trip from roughness, not from the map as a whole.
        blocking = [r for r in reasons if r not in ("not_rigid", "handheld")]
        self.conn.execute(
            "UPDATE sessions SET exclusion_reasons = %s, include_in_agg = %s WHERE session_id = %s",
            (reasons, status == "complete" and not blocking, session_id),
        )

    # --- batches -------------------------------------------------------------------------

    def apply_batch(self, f: BatchFacts, received_at: dt.datetime) -> str:
        """Returns "new", "late" (older than a batch already processed), "duplicate" (the phone sent
        it again) or "replayed" (the same Event Hubs event read a second time by the processor).

        The batch itself (ingest_batches row, session counters, track) is all or nothing; labels,
        the signal processing and the live state are optional parts in their own savepoints, so a
        bad value in one of them can't lose the batch."""
        self._touch_device(f.device_id)
        self.conn.execute(
            """
            INSERT INTO sessions (session_id, device_id, source, started_at)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (session_id) DO UPDATE SET
              device_id = COALESCE(sessions.device_id, EXCLUDED.device_id),
              source = CASE WHEN EXCLUDED.source = 'replay' THEN 'replay' ELSE sessions.source END,
              started_at = COALESCE(sessions.started_at, EXCLUDED.started_at)
            """,
            (f.session_id, f.device_id, f.source, f.t0_utc),
        )
        last_seq, status = self.conn.execute(
            "SELECT last_batch_seq, status FROM sessions WHERE session_id = %s FOR UPDATE", (f.session_id,)
        ).fetchone()
        late = last_seq is not None and f.batch_seq < last_seq

        inserted = self.conn.execute(
            """
            INSERT INTO ingest_batches (session_id, batch_seq, device_id, t0_utc, end_utc, received_at,
                                        late, sample_counts)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (session_id, batch_seq) DO NOTHING
            RETURNING batch_seq
            """,
            (f.session_id, f.batch_seq, f.device_id, f.t0_utc, f.end_utc, received_at, late,
             Jsonb(f.sample_counts)),
        ).fetchone()
        if inserted is None:
            # A phone retry went through the ingest function again, so it has a new receivedAtUtc.
            # The same received time means the processor read the same event twice (a replay after
            # a restart or a lost partition): not the phone's doing, so not counted.
            first_received = self.conn.execute(
                "SELECT received_at FROM ingest_batches WHERE session_id = %s AND batch_seq = %s",
                (f.session_id, f.batch_seq),
            ).fetchone()[0]
            if first_received == received_at:
                return "replayed"
            self.conn.execute(
                "UPDATE sessions SET duplicate_batches = duplicate_batches + 1, updated_at = now() "
                "WHERE session_id = %s",
                (f.session_id,),
            )
            return "duplicate"
        if status != "live":
            self._reopen(f.session_id)  # new data for an ended trip: finalize it again

        if f.fixes:
            with self.conn.cursor() as cur:
                cur.executemany(
                    """
                    INSERT INTO track_points (session_id, t, geom, speed_ms, course_deg, h_acc_m)
                    VALUES (%s, %s, ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, %s, %s, %s)
                    ON CONFLICT (session_id, t) DO NOTHING
                    """,
                    [(f.session_id, x.t, x.lon, x.lat, x.speed_ms, x.course_deg, x.h_acc_m)
                     for x in f.fixes],
                )
        self.conn.execute(
            """
            UPDATE sessions SET
              received_batches = received_batches + 1,
              late_batches = late_batches + %s,
              last_batch_seq = GREATEST(COALESCE(last_batch_seq, -1), %s),
              last_received_at = GREATEST(COALESCE(last_received_at, %s), %s),
              updated_at = now()
            WHERE session_id = %s
            """,
            (int(late), f.batch_seq, received_at, received_at, f.session_id),
        )

        if f.labels:
            self._optional("labels", f.session_id, lambda: self._insert_labels(f))
        if status == "complete":
            # Already finalized (e.g. closed after 15 silent minutes, then the phone's backlog came):
            # the trip was reopened above, and the finalize job recomputes it whole from the archive.
            pass
        elif not late:
            # Late batches skip the signal processing: the filters have moved past them. The
            # finalize job recomputes the whole trip in one pass.
            ok, result = self._optional("signal", f.session_id, lambda: self._process_signal(f))
            covered = ok and result is None  # already in the finalize job's state (trip reopened above)
            if ok and not covered:
                roughness_now, msdv = result
            elif not ok:
                # signal_state wasn't advanced, so the next batch restarts the filters (a gap).
                roughness_now = None
                msdv = self.conn.execute(
                    "SELECT sqrt(msdv_z ^ 2 + coalesce(msdv_y, 0) ^ 2) FROM sessions WHERE session_id = %s",
                    (f.session_id,)).fetchone()[0]
            if not covered:
                self._optional("live_state", f.session_id,
                               lambda: self._update_live_state(f, received_at, roughness_now, msdv))
        self._mark_processing_when_complete(f.session_id)
        self._refresh_exclusions(f.session_id)
        return "late" if late else "new"

    def _insert_labels(self, f: BatchFacts) -> None:
        with self.conn.cursor() as cur:
            cur.executemany(
                "INSERT INTO labels (session_id, t, type, value, note) VALUES (%s, %s, %s, %s, %s) "
                "ON CONFLICT (session_id, t, type) DO NOTHING",
                [(f.session_id, lab.t, lab.type, lab.value, lab.note) for lab in f.labels],
            )

    def _process_signal(self, f: BatchFacts) -> tuple[float | None, float] | None:
        """Runs one batch through the trip's pipeline and saves its results and state. None: the
        state already covers this batch."""
        row = self.conn.execute(
            "SELECT state, last_batch_seq FROM signal_state WHERE session_id = %s FOR UPDATE",
            (f.session_id,),
        ).fetchone()
        if row is not None and row[1] is not None and f.batch_seq <= row[1]:
            # The finalize job read the archive further than the stream (a trip closed while its
            # batches were still in the backlog) and saved its one-pass state. Feeding this batch
            # again would count its dose twice and write a second set of series rows.
            return None
        # A missing batch means the filters would see a jump: restart them (the dose is kept).
        reset = row is not None and f.batch_seq != row[1] + 1
        pipeline = Pipeline(row[0] if row else None)
        # The pipeline runs on the phone's uptime clock; GPS fixes (UTC) are moved onto it and the
        # outputs back to UTC with the trip clock's offset, which never runs backwards (clock.py).
        trip_clock = clock.TripClock.from_state((row[0] or {}).get("clock") if row else None)
        off = trip_clock.offset(f.clock_offset)
        shift = off - f.clock_offset  # derived time − phone time, for looking up the stored fixes
        out = pipeline.feed(
            np.asarray(f.motion_t, dtype=float),
            np.asarray(f.motion_ua, dtype=float).reshape(-1, 3),
            np.asarray(f.motion_g, dtype=float).reshape(-1, 3),
            [(clock.fix_uptime(f, x), x.speed_ms) for x in f.fixes],
            reset=reset,
            rr=np.asarray(f.motion_rr, dtype=float).reshape(-1, 3),
            moved=f.phone_moved_up,
        )
        if out.series:
            with self.conn.cursor() as cur:
                cur.executemany(
                    "INSERT INTO session_series (session_id, t, a_vert, a_lat, a_lon, speed_ms, msdv) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s) ON CONFLICT (session_id, t) DO NOTHING",
                    [(f.session_id, from_epoch(p.t + off), p.a_vert, p.a_lat, p.a_lon, p.speed, p.msdv)
                     for p in out.series],
                )
        for e in out.events:
            e.t += off
            # Position of the nearest GPS fix of this trip (≈ 1 Hz, so within about half a second).
            self.conn.execute(
                """
                INSERT INTO events (session_id, type, t, geom, speed_ms, magnitude, confidence)
                VALUES (%s, %s, %s,
                        (SELECT geom FROM track_points WHERE session_id = %s
                         ORDER BY abs(extract(epoch FROM t - %s)) LIMIT 1),
                        %s, %s, %s)
                ON CONFLICT (session_id, type, t) DO NOTHING
                """,
                (f.session_id, e.type, from_epoch(e.t), f.session_id, from_epoch(e.t - shift), e.speed,
                 e.magnitude, e.confidence),
            )
        self.conn.execute(
            """
            INSERT INTO signal_state (session_id, state, last_batch_seq, gaps, updated_at)
            VALUES (%s, %s, %s, %s, now())
            ON CONFLICT (session_id) DO UPDATE SET
              state = EXCLUDED.state, last_batch_seq = EXCLUDED.last_batch_seq,
              gaps = signal_state.gaps + EXCLUDED.gaps, updated_at = now()
            """,
            (f.session_id, Jsonb({**pipeline.to_state(), "clock": trip_clock.to_state()}), f.batch_seq,
             int(out.reset)),
        )
        self.conn.execute("UPDATE sessions SET msdv_z = %s, msdv_y = %s WHERE session_id = %s",
                          (out.msdv_z, out.msdv_y, f.session_id))
        return out.roughness_now, out.msdv

    def _update_live_state(self, f: BatchFacts, received_at: dt.datetime,
                           roughness_now: float | None, msdv: float | None) -> None:
        fix = f.last_fix
        # Without a new fix, keep the previous position, but only within the same trip.
        keep = "CASE WHEN EXCLUDED.fix_at IS NOT NULL THEN EXCLUDED.{c} " \
               "WHEN live_state.session_id = EXCLUDED.session_id THEN live_state.{c} END"
        cols = ("fix_at", "lat", "lon", "speed_ms", "course_deg", "h_acc_m")
        self.conn.execute(
            f"""
            INSERT INTO live_state (device_id, session_id, updated_at, received_at, fix_at, lat, lon,
                                    speed_ms, course_deg, h_acc_m, battery, thermal, low_power,
                                    roughness_now, msdv_so_far)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (device_id) DO UPDATE SET
              session_id = EXCLUDED.session_id,
              updated_at = EXCLUDED.updated_at,
              received_at = EXCLUDED.received_at,
              {", ".join(f"{c} = {keep.format(c=c)}" for c in cols)},
              battery = EXCLUDED.battery,
              thermal = EXCLUDED.thermal,
              low_power = EXCLUDED.low_power,
              roughness_now = EXCLUDED.roughness_now,
              msdv_so_far = EXCLUDED.msdv_so_far
            -- By arrival, not by the phone's clock: after a backward step the device would stay frozen,
            -- into its next trip, until the clock caught up.
            WHERE EXCLUDED.received_at >= live_state.received_at
            """,
            (f.device_id, f.session_id, f.end_utc, received_at,
             fix.t if fix else None, fix.lat if fix else None, fix.lon if fix else None,
             fix.speed_ms if fix else None, fix.course_deg if fix else None,
             fix.h_acc_m if fix else None, f.battery, f.thermal, f.low_power,
             roughness_now, msdv),
        )

    # --- session metadata ----------------------------------------------------------------

    def apply_session(self, s: SessionFacts) -> str:
        """Returns "applied", or "stale_start" for a Start copy that arrived after the Stop copy."""
        self._touch_device(s.device_id)
        self.conn.execute(
            "INSERT INTO sessions (session_id, device_id, started_at) VALUES (%s, %s, %s) "
            "ON CONFLICT (session_id) DO NOTHING",
            (s.session_id, s.device_id, s.started_at),
        )
        has_stop, status = self.conn.execute(
            "SELECT expected_batch_count IS NOT NULL, status FROM sessions WHERE session_id = %s FOR UPDATE",
            (s.session_id,),
        ).fetchone()
        if s.phase == "start" and has_stop:
            return "stale_start"

        self.conn.execute(
            """
            UPDATE sessions SET
              device_id = COALESCE(device_id, %s),
              context_known = true,
              vehicle_type = %s, vehicle_make_model = %s, vehicle_line = %s,
              mount = %s, people = %s, conditions = %s,
              synthetic_sensors = %s, recovered = %s,
              metadata = %s,
              started_at = COALESCE(%s, started_at),
              ended_at = COALESCE(%s, ended_at),
              expected_batch_count = COALESCE(%s, expected_batch_count),
              replay_of = COALESCE(%s, replay_of),
              source = CASE WHEN %s::text IS NOT NULL THEN 'replay' ELSE source END,
              updated_at = now()
            WHERE session_id = %s
            """,
            (s.device_id, s.vehicle_type, s.vehicle_make_model, s.vehicle_line,
             Jsonb(s.mount), Jsonb(s.people), Jsonb(s.conditions) if s.conditions is not None else None,
             s.synthetic_sensors, s.recovered, Jsonb(s.metadata),
             s.started_at, s.ended_at, s.batch_count, s.replay_of, s.replay_of, s.session_id),
        )
        if s.phase == "stop" and not has_stop and status != "live":
            self._reopen(s.session_id)  # the Stop copy came after the 15-minute close
        self._mark_processing_when_complete(s.session_id)
        self._refresh_exclusions(s.session_id)
        return "applied"
