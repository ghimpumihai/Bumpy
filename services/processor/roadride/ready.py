"""Trip end → "session ready" on the Service Bus queue (plan §5 "Trip end").

A trip becomes ready in two ways:
- the stream processor sees its Stop copy and every batch (store.Store marks it `processing`), or
- it goes silent: no batch for 15 minutes closes it as `processing` + `incomplete`. The 15 minutes
  are counted up to how far the stream processor has read, not up to now: after an outage, a trip
  whose batches are still in the backlog is not silent.

A background thread in the stream processor sends the message for every `processing` trip that
hasn't had one, and records it in `sessions.ready_sent_at`. Sending only after the database commit
(never inside the Event Hubs transaction) means a crash can lose a send but never sends for rows
that were rolled back; the next sweep finds the trip again. A trip stuck in `processing` long after
its message (a job that died, a dead letter fixed by hand) gets it again. The finalize job is
idempotent, so a repeated message only costs a rerun.
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import threading
from typing import Callable

from psycopg import Connection

log = logging.getLogger(__name__)

IDLE_CLOSE_MIN = 15  # plan §5: no new batch for 15 minutes → closed as incomplete
RESEND_AFTER_MIN = 45  # longer than a finalize run can take (30-minute job limit)
SWEEP_EVERY_S = 60.0
BATCH_LIMIT = 100


def close_idle(conn: Connection, read_up_to: dt.datetime) -> list[str]:
    """`read_up_to`: everything ingest received before it has been applied (stream.PartitionWriter).
    last_received_at is ingest's receive time, so comparing it with now() would close a live trip
    whose newer batches are only waiting in the processor's backlog."""
    rows = conn.execute(
        """
        UPDATE sessions SET status = 'processing', updated_at = now(),
          incomplete = (expected_batch_count IS NULL OR received_batches < expected_batch_count)
        WHERE status = 'live' AND received_batches > 0
          AND COALESCE(last_received_at, updated_at) < %s - make_interval(mins => %s)
        RETURNING session_id
        """,
        (read_up_to, IDLE_CLOSE_MIN),
    ).fetchall()
    return [r[0] for r in rows]


def due(conn: Connection) -> list[str]:
    rows = conn.execute(
        """
        SELECT session_id FROM sessions
        WHERE status = 'processing'
          AND (ready_sent_at IS NULL OR ready_sent_at < now() - make_interval(mins => %s))
        ORDER BY updated_at LIMIT %s
        """,
        (RESEND_AFTER_MIN, BATCH_LIMIT),
    ).fetchall()
    return [r[0] for r in rows]


def mark_sent(conn: Connection, session_id: str) -> None:
    conn.execute("UPDATE sessions SET ready_sent_at = now() WHERE session_id = %s", (session_id,))


def message_body(session_id: str) -> str:
    return json.dumps({"sessionId": session_id, "reason": "trip_end"})


def sweep(conn: Connection, send, read_up_to: dt.datetime | None) -> list[str]:
    """One pass: close silent trips, then send for every trip that is due. `conn` is autocommit;
    `send(body)` raises on failure; `read_up_to` None (the processor hasn't heard from every
    partition yet) closes nothing. Returns the IDs sent."""
    closed = close_idle(conn, read_up_to) if read_up_to is not None else []
    if closed:
        log.info("closed %d silent trip(s) as incomplete: %s", len(closed), ", ".join(closed))
    sent = []
    for sid in due(conn):
        send(message_body(sid))
        mark_sent(conn, sid)
        sent.append(sid)
    if sent:
        log.info("session ready sent for %s", ", ".join(sent))
    return sent


class ServiceBusSender:
    def __init__(self, namespace: str, queue: str):
        from azure.identity import DefaultAzureCredential
        from azure.servicebus import ServiceBusClient

        self._client = ServiceBusClient(namespace, DefaultAzureCredential(exclude_interactive_browser_credential=True))
        self._sender = self._client.get_queue_sender(queue)

    def __call__(self, body: str) -> None:
        from azure.servicebus import ServiceBusMessage

        self._sender.send_messages(ServiceBusMessage(body, content_type="application/json"))


class ReadyNotifier(threading.Thread):
    """Sweeps every minute, and right away when the stream processor ends a trip (`kick`)."""

    def __init__(self, send, connect, read_up_to: Callable[[], dt.datetime | None]):
        super().__init__(name="ready-notifier", daemon=True)
        self._send = send
        self._connect = connect
        self._read_up_to = read_up_to
        self._wake = threading.Event()

    def kick(self) -> None:
        self._wake.set()

    def run(self) -> None:
        while True:
            self._wake.wait(SWEEP_EVERY_S)
            self._wake.clear()
            try:
                with self._connect(autocommit=True, application_name="roadride-ready") as conn:
                    sweep(conn, self._send, self._read_up_to())
            except Exception:  # noqa: BLE001 - the next sweep tries again
                log.exception("session-ready sweep failed")
