"""Database writes for the live path. The caller owns the transaction (one per Event Hubs batch),
so the rows and the stream checkpoint commit together."""

from __future__ import annotations

import datetime as dt

import numpy as np
from psycopg import Connection
from psycopg.types.json import Jsonb

from .dsp import Pipeline
from .live import BatchFacts, SessionFacts, exclusion_reasons


def from_epoch(seconds: float) -> dt.datetime:
    return dt.datetime.fromtimestamp(seconds, tz=dt.timezone.utc)


class Store:
    def __init__(self, conn: Connection):
        self.conn = conn

    # --- checkpoints ---------------------------------------------------------------------

    def load_checkpoints(self, eventhub: str, consumer_group: str) -> dict[str, int]:
        rows = self.conn.execute(
            "SELECT partition_id, sequence_number FROM stream_checkpoints "
            "WHERE eventhub = %s AND consumer_group = %s",
            (eventhub, consumer_group),
        ).fetchall()
        return {pid: seq for pid, seq in rows}

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
        (plan §5 "Trip end"). Sending "session ready" to the queue comes with the finalize job."""
        self.conn.execute(
            """
            UPDATE sessions s SET status = 'processing', updated_at = now()
            WHERE s.session_id = %s AND s.status = 'live' AND s.expected_batch_count IS NOT NULL
              AND (SELECT count(*) FROM ingest_batches b
                   WHERE b.session_id = s.session_id AND b.batch_seq < s.expected_batch_count)
                  >= s.expected_batch_count
            """,
            (session_id,),
        )

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
        """Returns "new", "late" (older than a batch already processed) or "duplicate"."""
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
        last_seq = self.conn.execute(
            "SELECT last_batch_seq FROM sessions WHERE session_id = %s FOR UPDATE", (f.session_id,)
        ).fetchone()[0]
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
            self.conn.execute(
                "UPDATE sessions SET duplicate_batches = duplicate_batches + 1, updated_at = now() "
                "WHERE session_id = %s",
                (f.session_id,),
            )
            return "duplicate"

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
        if f.labels:
            with self.conn.cursor() as cur:
                cur.executemany(
                    "INSERT INTO labels (session_id, t, type, value, note) VALUES (%s, %s, %s, %s, %s) "
                    "ON CONFLICT (session_id, t, type) DO NOTHING",
                    [(f.session_id, lab.t, lab.type, lab.value, lab.note) for lab in f.labels],
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

        if not late:
            # Late batches skip the signal processing: the filters have moved past them. The
            # finalize job recomputes the whole trip in one pass.
            roughness_now, msdv = self._process_signal(f)
            self._update_live_state(f, received_at, roughness_now, msdv)
        self._mark_processing_when_complete(f.session_id)
        self._refresh_exclusions(f.session_id)
        return "late" if late else "new"

    def _process_signal(self, f: BatchFacts) -> tuple[float | None, float]:
        """Runs one batch through the trip's pipeline and saves its results and state."""
        row = self.conn.execute(
            "SELECT state, last_batch_seq FROM signal_state WHERE session_id = %s FOR UPDATE",
            (f.session_id,),
        ).fetchone()
        # A missing batch means the filters would see a jump: restart them (the dose is kept).
        reset = row is not None and f.batch_seq != row[1] + 1
        pipeline = Pipeline(row[0] if row else None)
        out = pipeline.feed(
            np.asarray(f.motion_t, dtype=float),
            np.asarray(f.motion_ua, dtype=float).reshape(-1, 3),
            np.asarray(f.motion_g, dtype=float).reshape(-1, 3),
            [(x.t.timestamp(), x.speed_ms) for x in f.fixes],
            reset=reset,
        )
        if out.series:
            with self.conn.cursor() as cur:
                cur.executemany(
                    "INSERT INTO session_series (session_id, t, a_vert, a_lat, a_lon, speed_ms, msdv) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s) ON CONFLICT (session_id, t) DO NOTHING",
                    [(f.session_id, from_epoch(p.t), p.a_vert, p.a_lat, p.a_lon, p.speed, p.msdv)
                     for p in out.series],
                )
        for e in out.events:
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
                (f.session_id, e.type, from_epoch(e.t), f.session_id, from_epoch(e.t), e.speed,
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
            (f.session_id, Jsonb(pipeline.to_state()), f.batch_seq, int(out.reset)),
        )
        self.conn.execute("UPDATE sessions SET msdv_z = %s WHERE session_id = %s", (out.msdv, f.session_id))
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
            WHERE EXCLUDED.updated_at >= live_state.updated_at
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
        has_stop = self.conn.execute(
            "SELECT expected_batch_count IS NOT NULL FROM sessions WHERE session_id = %s FOR UPDATE",
            (s.session_id,),
        ).fetchone()[0]
        if s.phase == "start" and has_stop:
            return "stale_start"

        self.conn.execute(
            """
            UPDATE sessions SET
              device_id = COALESCE(device_id, %s),
              context_known = true,
              vehicle_type = %s, vehicle_make_model = %s, vehicle_line = %s,
              mount = %s, people = %s, conditions = %s,
              audio_enabled = %s, synthetic_sensors = %s, recovered = %s,
              metadata = %s,
              started_at = COALESCE(%s, started_at),
              ended_at = COALESCE(%s, ended_at),
              expected_batch_count = COALESCE(%s, expected_batch_count),
              updated_at = now()
            WHERE session_id = %s
            """,
            (s.device_id, s.vehicle_type, s.vehicle_make_model, s.vehicle_line,
             Jsonb(s.mount), Jsonb(s.people), Jsonb(s.conditions) if s.conditions is not None else None,
             s.audio_enabled, s.synthetic_sensors, s.recovered, Jsonb(s.metadata),
             s.started_at, s.ended_at, s.batch_count, s.session_id),
        )
        self._mark_processing_when_complete(s.session_id)
        self._refresh_exclusions(s.session_id)
        return "applied"
