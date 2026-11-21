"""The stream processor (plan §5 "Stream processor"): reads Event Hubs and writes the live tables.

Ordering and exactly-once effect:
- The ingest function uses the device ID as the partition key, so each phone's messages arrive in
  order on one partition.
- Each received batch of events is written in ONE database transaction together with the
  partition's checkpoint (stream_checkpoints). On start, reading resumes after the saved sequence
  number, so a crash or redeploy neither loses nor double-counts anything. After each commit the
  SDK's (in-memory) checkpoint is moved too, so a partition the SDK closes and claims again after an
  error resumes there instead of at the start-up position.
- A bad event is skipped (inside a savepoint) and logged, so it can't block its partition. Only a lost
  connection is retried: psycopg reports many errors that would fail the same way every time
  (index row too large, disk full, timeouts, ...) as OperationalError too.
- A connection that stays lost after a reconnect stops the process; Container Apps restarts it and
  it resumes from the last committed checkpoint.

Threads: the SDK's synchronous client serves all partitions from ONE thread, in turn. Each call
returns a partition's buffered events once 100 are waiting or `max_wait_time` (1 s) after the last
call, so an event can wait up to about a second before it is written. That fits the 10 s budget from
phone to screen, and keeps the number of transactions and empty callbacks low; the async client
would be needed to serve partitions in parallel.
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
import threading
import time
from typing import Callable

import psycopg
from azure.eventhub import EventData, EventHubConsumerClient
from azure.identity import DefaultAzureCredential

from . import telemetry
from .db import connect, is_connection_loss, is_retryable_conflict
from .live import parse_batch, parse_iso, parse_session
from .ready import ReadyNotifier, ServiceBusSender
from .store import Store

log = logging.getLogger(__name__)

CONSUMER_GROUP = "$Default"  # Event Hubs Basic has only the default consumer group

WRITE_ATTEMPTS = 2  # per batch of events, each on a fresh connection, before the process exits
RETRY_DELAY_S = 2.0
CONFLICT_ATTEMPTS = 3  # per event, for deadlocks and serialization failures

UTC = dt.timezone.utc


def _prop(event: EventData, name: str):
    """Application properties arrive with bytes keys and bytes string values."""
    props = event.properties or {}
    value = props.get(name.encode(), props.get(name))
    return value.decode() if isinstance(value, bytes) else value


def handle_event(store: Store, event: EventData) -> str:
    body = json.loads(event.body_as_str(encoding="UTF-8"))
    kind = _prop(event, "kind") or ("batch" if "batchSeq" in body else "session")
    if kind == "session":
        return "session:" + store.apply_session(parse_session(body))
    received = parse_iso(_prop(event, "receivedAtUtc")) or event.enqueued_time \
        or dt.datetime.now(UTC)
    return "batch:" + store.apply_batch(parse_batch(body), received)


def _log_fields(partition_id: str, count: int, seq: int, lag: float | None,
                outcomes: dict[str, int]) -> dict:
    """The commit line's values as separate fields (customDimensions in Application Insights)."""
    fields = {"partition_id": partition_id, "event_count": count, "sequence_number": seq}
    if lag is not None:
        fields["lag_s"] = round(lag, 3)
    fields.update({"outcome_" + k.replace(":", "_"): v for k, v in outcomes.items()})
    return fields


class PartitionWriter:
    """One database connection per partition (the lock keeps that safe if the SDK ever calls back
    from several threads)."""

    def __init__(self, eventhub: str,
                 connect_fn: Callable[[str], psycopg.Connection] | None = None, on_trip_end=None):
        self.eventhub = eventhub
        self.on_trip_end = on_trip_end  # called after a commit that ended at least one trip
        self._connect = connect_fn or (
            lambda pid: connect(application_name=f"roadride-stream-{pid}"))
        self._conns: dict[str, psycopg.Connection] = {}
        self._lock = threading.Lock()
        # For the lag metric: partition -> (enqueued time of the last committed event, caught up?)
        self._progress: dict[str, tuple[dt.datetime | None, bool]] = {}

    def _conn(self, partition_id: str) -> psycopg.Connection:
        with self._lock:
            conn = self._conns.get(partition_id)
            if conn is None or conn.closed:
                conn = self._connect(partition_id)
                self._conns[partition_id] = conn
            return conn

    def _drop(self, partition_id: str) -> None:
        with self._lock:
            conn = self._conns.pop(partition_id, None)
        if conn is not None:
            try:
                conn.close()
            except Exception:  # noqa: BLE001
                pass

    def write(self, partition_id: str, events: list[EventData]) -> None:
        """Writes the events and the checkpoint, or exits the process if the database stays out of
        reach. Any other failure outside an event's savepoint is raised to the SDK, which closes the
        partition and reads it again from the last checkpoint."""
        for attempt in range(1, WRITE_ATTEMPTS + 1):
            conn = None
            try:
                conn = self._conn(partition_id)  # a failed connect or Entra token counts as lost
                self._write_once(conn, partition_id, events)
                return
            except Exception as exc:  # noqa: BLE001
                if conn is not None and not is_connection_loss(exc, conn):
                    raise
                log.warning("database connection lost on partition %s (attempt %d)", partition_id,
                            attempt, exc_info=True)
                self._drop(partition_id)  # reconnect with a fresh Entra token
                time.sleep(RETRY_DELAY_S)
        log.critical("database unavailable; exiting so the app restarts from the last checkpoint")
        os._exit(1)  # the SDK would otherwise move past these events

    def _apply_event(self, conn: psycopg.Connection, store: Store, partition_id: str,
                     event: EventData) -> tuple[str, dict[str, int]]:
        for attempt in range(1, CONFLICT_ATTEMPTS + 1):
            store.dropped = {}
            try:
                with conn.transaction():  # savepoint: a bad event can't undo the others
                    return handle_event(store, event), store.dropped
            except Exception as exc:  # noqa: BLE001
                if is_connection_loss(exc, conn):
                    raise
                if is_retryable_conflict(exc) and attempt < CONFLICT_ATTEMPTS:
                    log.warning("conflict on event seq=%s on partition %s, retrying: %r",
                                event.sequence_number, partition_id, exc)
                    continue
                # Poison event: anything else fails the same way on every replay. Log it and move
                # on; the raw archive still has the message.
                log.exception("skipping event seq=%s on partition %s", event.sequence_number,
                              partition_id)
                return "skipped", {}
        raise AssertionError("unreachable")

    def _write_once(self, conn: psycopg.Connection, partition_id: str, events: list[EventData]) -> None:
        store = Store(conn)
        outcomes: dict[str, int] = {}
        with conn.transaction():
            for event in events:
                outcome, dropped = self._apply_event(conn, store, partition_id, event)
                outcomes[outcome] = outcomes.get(outcome, 0) + 1
                for part, n in dropped.items():
                    outcomes[f"dropped_{part}"] = outcomes.get(f"dropped_{part}", 0) + n
            last = events[-1]
            store.save_checkpoint(self.eventhub, CONSUMER_GROUP, partition_id, last.sequence_number,
                                  last.enqueued_time)
        if store.ended and self.on_trip_end:
            self.on_trip_end()  # after the commit: the notifier reads the committed `processing` rows
        self._progress[partition_id] = (last.enqueued_time, False)
        lag = (dt.datetime.now(UTC) - last.enqueued_time).total_seconds() \
            if last.enqueued_time else None
        log.info("partition=%s events=%d seq=%d lag_s=%s %s", partition_id, len(events),
                 last.sequence_number, f"{lag:.1f}" if lag is not None else "-",
                 " ".join(f"{k}={v}" for k, v in sorted(outcomes.items())),
                 extra=_log_fields(partition_id, len(events), last.sequence_number, lag, outcomes))

    def idle(self, partition_id: str) -> None:
        """The SDK found nothing new on the partition: it is read to its end."""
        enqueued, _ = self._progress.get(partition_id, (None, False))
        self._progress[partition_id] = (enqueued, True)
    def lag_seconds(self) -> dict[str, float]:
        """Processor lag per partition (plan §5): now minus the enqueued time of the last processed
        event, or 0 when the partition is read to its end."""
        now = dt.datetime.now(UTC)
        return {pid: 0.0 if caught_up or enqueued is None else max(0.0, (now - enqueued).total_seconds())
                for pid, (enqueued, caught_up) in list(self._progress.items())}


# --- Where to start reading ------------------------------------------------------------------

def resume_position(saved: tuple[int, dt.datetime | None] | None, partition: dict,
                    hub_created_at: dt.datetime | None) -> tuple[int | str, str | None]:
    """Where to start reading a partition: (position, warning). "-1" is the earliest event kept.

    The saved sequence number is only valid for the event hub it came from. Terraform replaces the
    hub when partition_count changes, and the new hub numbers its events from 0 again; resuming after
    the old number would silently skip every event up to it.
    """
    if saved is None:
        return "-1", None  # never read: from the start, since Event Hubs keeps only a day
    seq, saved_at = saved
    last = partition.get("last_enqueued_sequence_number")
    begin = partition.get("beginning_sequence_number")
    if hub_created_at is not None and saved_at is not None and hub_created_at > saved_at:
        return "-1", (f"event hub created at {hub_created_at.isoformat()}, after the checkpoint "
                      f"(seq {seq}, saved {saved_at.isoformat()}): it was recreated; reading from the "
                      "earliest event")
    if last is not None and seq > last:
        return "-1", (f"checkpoint seq {seq} is beyond the partition's last event ({last}): the hub "
                      "was probably recreated; reading from the earliest event")
    if begin is not None and not partition.get("is_empty") and seq < begin - 1:
        return "-1", (f"events {seq + 1}..{begin - 1} expired before they were read (retention); "
                      "reading from the earliest event kept")
    return seq, None


def starting_positions(client: EventHubConsumerClient, saved: dict[str, tuple[int, dt.datetime]]
                       ) -> tuple[list[str], dict[str, int | str]]:
    hub = client.get_eventhub_properties()
    created = hub.get("created_at")
    positions: dict[str, int | str] = {}
    for pid in hub["partition_ids"]:
        position, warning = resume_position(saved.get(pid), client.get_partition_properties(pid),
                                            created)
        if warning:
            log.error("partition %s: %s", pid, warning)
        positions[pid] = position
    return list(hub["partition_ids"]), positions


def callbacks(writer: PartitionWriter):
    """The SDK callbacks: (on_event_batch, on_error)."""

    def on_event_batch(partition_context, events):
        if events:
            writer.write(partition_context.partition_id, events)
            # Committed: move the SDK's in-memory checkpoint too. Without it, a partition the SDK
            # closes and claims again after an error restarts at the start-up position and replays
            # everything since (up to a day).
            partition_context.update_checkpoint(events[-1])
        else:
            writer.idle(partition_context.partition_id)

    def on_error(partition_context, error):
        pid = partition_context.partition_id if partition_context else "-"
        log.error("Event Hubs error on partition %s: %r", pid, error)

    return on_event_batch, on_error


def run() -> None:
    namespace = os.environ["EVENTHUB_FULLY_QUALIFIED_NAMESPACE"]
    eventhub = os.environ["EVENTHUB_NAME"]
    client = EventHubConsumerClient(
        fully_qualified_namespace=namespace,
        eventhub_name=eventhub,
        consumer_group=CONSUMER_GROUP,
        credential=DefaultAzureCredential(exclude_interactive_browser_credential=True),
    )
    with connect(application_name="roadride-stream") as conn:
        saved = Store(conn).load_checkpoint_rows(eventhub, CONSUMER_GROUP)
    # Resume after each saved checkpoint (unless the hub was recreated); read unseen partitions from
    # the start ("-1"), since Event Hubs keeps only a day and every batch counts.
    _, starting = starting_positions(client, saved)
    log.info("starting from %s", starting)

    notifier = ReadyNotifier(
        ServiceBusSender(os.environ["SERVICEBUS_FULLY_QUALIFIED_NAMESPACE"], os.environ["SERVICEBUS_QUEUE_NAME"]),
        connect,
    )
    notifier.start()
    writer = PartitionWriter(eventhub, on_trip_end=notifier.kick)
    telemetry.observe_lag(writer.lag_seconds)

    on_event_batch, on_error = callbacks(writer)
    with client:
        client.receive_batch(
            on_event_batch=on_event_batch,
            on_error=on_error,
            max_batch_size=100,
            max_wait_time=1,  # also makes the SDK call back with [] when a partition is idle
            starting_position=starting,
            starting_position_inclusive=False,
        )
