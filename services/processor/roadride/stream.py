"""The stream processor (plan §5 "Stream processor"): reads Event Hubs and writes the live tables.

Ordering and exactly-once effect:
- The ingest function uses the device ID as the partition key, so each phone's messages arrive in
  order on one partition.
- Each received batch of events is written in ONE database transaction together with the
  partition's checkpoint (stream_checkpoints). On start, reading resumes after the saved sequence
  number, so a crash or redeploy neither loses nor double-counts anything.
- A single bad event is skipped (inside a savepoint) and logged, so it can't block its partition.
- Database trouble that persists after a reconnect stops the process; Container Apps restarts it and
  it resumes from the last committed checkpoint.
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
import threading
import time

import psycopg
from azure.eventhub import EventData, EventHubConsumerClient
from azure.identity import DefaultAzureCredential

from .db import connect
from .live import parse_batch, parse_iso, parse_session
from .store import Store

log = logging.getLogger(__name__)

CONSUMER_GROUP = "$Default"  # Event Hubs Basic has only the default consumer group


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
        or dt.datetime.now(dt.timezone.utc)
    return "batch:" + store.apply_batch(parse_batch(body), received)


class PartitionWriter:
    """One database connection per partition: the client calls back from one thread per partition."""

    def __init__(self, eventhub: str):
        self.eventhub = eventhub
        self._conns: dict[str, psycopg.Connection] = {}
        self._lock = threading.Lock()

    def _conn(self, partition_id: str) -> psycopg.Connection:
        with self._lock:
            conn = self._conns.get(partition_id)
            if conn is None or conn.closed:
                conn = connect(application_name=f"roadride-stream-{partition_id}")
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
        for attempt in (1, 2):
            conn = self._conn(partition_id)
            try:
                self._write_once(conn, partition_id, events)
                return
            except psycopg.OperationalError:
                log.warning("database connection lost on partition %s (attempt %d)", partition_id, attempt,
                            exc_info=True)
                self._drop(partition_id)  # reconnect with a fresh Entra token
                time.sleep(2)
        log.critical("database unavailable; exiting so the app restarts from the last checkpoint")
        os._exit(1)  # the SDK would otherwise move past these events

    def _write_once(self, conn: psycopg.Connection, partition_id: str, events: list[EventData]) -> None:
        store = Store(conn)
        outcomes: dict[str, int] = {}
        with conn.transaction():
            for event in events:
                try:
                    with conn.transaction():  # savepoint: a bad event can't undo the others
                        outcome = handle_event(store, event)
                except psycopg.OperationalError:
                    raise
                except Exception:  # noqa: BLE001 - poison event: log it and move on
                    log.exception("skipping event seq=%s on partition %s", event.sequence_number,
                                  partition_id)
                    outcome = "skipped"
                outcomes[outcome] = outcomes.get(outcome, 0) + 1
            last = events[-1]
            store.save_checkpoint(self.eventhub, CONSUMER_GROUP, partition_id, last.sequence_number,
                                  last.enqueued_time)
        lag = (dt.datetime.now(dt.timezone.utc) - last.enqueued_time).total_seconds() \
            if last.enqueued_time else None
        log.info("partition=%s events=%d seq=%d lag_s=%s %s", partition_id, len(events),
                 last.sequence_number, f"{lag:.1f}" if lag is not None else "-",
                 " ".join(f"{k}={v}" for k, v in sorted(outcomes.items())))


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
        saved = Store(conn).load_checkpoints(eventhub, CONSUMER_GROUP)
    # Resume after each saved checkpoint; read unseen partitions from the start ("-1"), since
    # Event Hubs keeps only a day and every batch counts.
    starting = {pid: saved.get(pid, "-1") for pid in client.get_partition_ids()}
    log.info("starting from %s", starting)

    writer = PartitionWriter(eventhub)

    def on_event_batch(partition_context, events):
        if events:
            writer.write(partition_context.partition_id, events)

    def on_error(partition_context, error):
        pid = partition_context.partition_id if partition_context else "-"
        log.error("Event Hubs error on partition %s: %r", pid, error)

    with client:
        client.receive_batch(
            on_event_batch=on_event_batch,
            on_error=on_error,
            max_batch_size=100,
            max_wait_time=1,
            starting_position=starting,
            starting_position_inclusive=False,
        )
