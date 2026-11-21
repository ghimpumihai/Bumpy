#!/usr/bin/env python3
"""Replay a recorded trip through the live path (plan 02 §5, "Replay tool").

Reads a session folder exported from the iPhone app (or its .zip), rebuilds the 2-second batches
the phone sends (IngestBatch.swift, spec §6), and posts them to the real ingest API at real speed
or faster, with the session metadata at Start and Stop (spec §6.1) around them.

The replay is a new trip:
  - a new sessionId, `source: "replay"` and `replayOf: <original sessionId>`, so the backend
    never counts it in the aggregated map and nothing is counted twice;
  - its own deviceId (default `replay-<original deviceId>`), so it gets its own marker on the
    Live page next to a real phone;
  - every UTC time moved to "now", so the dashboard shows it as live. The phone's uptime clock
    (`t_up`, `t0Up`) is kept as recorded; the processor only needs it to be consistent.

Uses: the end-to-end test before a drive, the demo in a room without a car, and re-running a real
trip after a change to the signal processing (e.g. tuning the pothole threshold).

Python 3 standard library only.

    $env:REPLAY_DEVICE_KEY = "<key from add-device-key.ps1 -DeviceId replay>"
    python tools/replay/replay.py <session folder or .zip> --url https://<func>.azurewebsites.net
    python tools/replay/replay.py <folder> --url ... --speed 4 --from 600 --duration 300
    python tools/replay/replay.py <folder> --dry-run out/      # write the batches, send nothing
"""

from __future__ import annotations

import argparse
import copy
import csv
import datetime as dt
import getpass
import gzip
import json
import math
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterator

BATCH_SEC = 2.0  # the app's batch window (spec §6)
STALE_FIX_MARGIN_S = 5.0  # RecordingSession.staleFixMargin: fixes kept before the start
MAX_INFLATED = 200 * 1024  # the ingest function's limit on a decompressed body
UNITS = {"accel": "g", "gyro": "rad/s", "speed": "m/s", "pressure": "kPa"}
FIELD_UNITS = {  # IngestBatch.allFieldUnits
    "t": "s (relative to t0Up)", "t0Up": "s since boot", "t0UtcMs": "ms since Unix epoch (UTC)",
    "deviceMotion.ua": "g", "deviceMotion.g": "g", "deviceMotion.rr": "rad/s",
    "deviceMotion.q": "unitless quaternion", "accelRaw": "g", "gyroRaw": "rad/s",
    "location.tUtcMs": "ms since Unix epoch (UTC)", "location.lat": "deg", "location.lon": "deg",
    "location.alt": "m", "location.hAcc": "m", "location.speed": "m/s (-1 = invalid)",
    "location.speedAcc": "m/s", "location.course": "deg (-1 = invalid)",
    "altimeter.relAltM": "m", "altimeter.pressureKpa": "kPa",
    "device.battery": "fraction 0-1 (-1 = unknown)",
}

# Columnar blocks: batch block -> (CSV file, [(batch column, CSV column)]).
COLUMNAR = {
    "deviceMotion": ("device_motion", [(c, c) for c in (
        "ua_x", "ua_y", "ua_z", "g_x", "g_y", "g_z", "rr_x", "rr_y", "rr_z",
        "q_w", "q_x", "q_y", "q_z")]),
    "accelRaw": ("accel_raw", [("x", "x"), ("y", "y"), ("z", "z")]),
    "gyroRaw": ("gyro_raw", [("x", "x"), ("y", "y"), ("z", "z")]),
    "altimeter": ("altimeter", [("relAltM", "rel_alt_m"), ("pressureKpa", "pressure_kpa")]),
}
LOCATION_COLS = [("lat", "lat", 8), ("lon", "lon", 8), ("alt", "alt", 6), ("hAcc", "h_acc", 6),
                 ("speed", "speed", 6), ("speedAcc", "speed_acc", 6), ("course", "course", 6)]


class ReplayError(Exception):
    """A problem the user has to fix (bad folder, rejected batch, bad key)."""


# --- Numbers, as the app encodes them ------------------------------------------------------

def _num(s: str) -> float:
    """A CSV number; the app writes non-finite values as an empty field, and encodes them as 0."""
    try:
        v = float(s)
    except ValueError:
        return 0.0
    return v if math.isfinite(v) else 0.0


def _round(v: float, digits: int) -> float:
    return round(v, digits) + 0.0  # + 0.0 turns -0.0 into 0.0


def iso_ms(utc_ms: float) -> str:
    t = dt.datetime.fromtimestamp(utc_ms / 1000.0, tz=dt.timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


def parse_iso_ms(s: str) -> float:
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() * 1000.0


# --- Reading the session folder ------------------------------------------------------------

@dataclass
class Row:
    t_up: float
    utc_ms: float | None
    cols: dict[str, str]


class Stream:
    """One CSV file, read row by row in `t_up` order (the app appends in arrival order)."""

    def __init__(self, path: Path):
        self.path = path
        self._fh = None
        self._it: Iterator[Row] | None = None
        self._peek: Row | None = None
        if path.is_file():
            self._fh = open(path, newline="", encoding="utf-8", errors="replace")
            self._it = self._rows(csv.reader(self._fh))
            self._advance()

    def _rows(self, reader) -> Iterator[Row]:
        header = next(reader, None)
        if not header or header[0] != "t_up":
            return
        n = len(header)
        while True:
            try:
                r = next(reader)
            except StopIteration:
                return
            except csv.Error:  # a torn last line after a crash
                return
            if len(r) != n:
                continue  # truncated row (quick_check reports these)
            try:
                t_up = float(r[0])
            except ValueError:
                continue
            try:
                utc = float(r[1]) if r[1] else None
            except ValueError:
                utc = None
            yield Row(t_up, utc, dict(zip(header, r)))

    def _advance(self) -> None:
        self._peek = next(self._it, None) if self._it else None

    @property
    def first(self) -> Row | None:
        return self._peek

    def take_before(self, t_end: float) -> list[Row]:
        out = []
        while self._peek is not None and self._peek.t_up < t_end:
            out.append(self._peek)
            self._advance()
        return out

    def close(self) -> None:
        if self._fh:
            self._fh.close()


def last_t_up(path: Path) -> float | None:
    """`t_up` of the last complete row, read from the end of the file."""
    if not path.is_file():
        return None
    with open(path, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        size = fh.tell()
        fh.seek(max(0, size - 64 * 1024))
        tail = fh.read().decode("utf-8", errors="replace").splitlines()
    for line in reversed(tail[1:] if size > 64 * 1024 else tail):
        try:
            return float(line.split(",", 1)[0])
        except ValueError:
            continue
    return None


def open_session(path: Path, workdir: Path) -> Path:
    """The session folder itself, or the folder inside an exported .zip."""
    if path.is_dir():
        folder = path
    elif path.suffix.lower() == ".zip" and path.is_file():
        with zipfile.ZipFile(path) as z:
            for name in z.namelist():
                target = (workdir / name).resolve()
                if workdir.resolve() not in target.parents and target != workdir.resolve():
                    raise ReplayError(f"{path}: unsafe path in zip: {name}")
            z.extractall(workdir)
        found = sorted(p.parent for p in workdir.rglob("session.json"))
        if not found:
            raise ReplayError(f"{path}: no session.json in the zip")
        folder = found[0]
    else:
        raise ReplayError(f"{path}: not a session folder or .zip")
    if not (folder / "session.json").is_file():
        raise ReplayError(f"{folder}: no session.json (is this a session folder?)")
    if not (folder / "device_motion.csv").is_file():
        raise ReplayError(f"{folder}: no device_motion.csv")
    return folder


# --- Building batches ----------------------------------------------------------------------

@dataclass
class Plan:
    """What to send: the original session, the new identity and the time shift."""
    meta: dict
    session_id: str
    device_id: str
    start_up: float  # uptime of the first replayed window
    end_up: float  # uptime where the replay stops
    shift_ms: float = 0.0  # added to every original UTC time
    windows: int = field(init=False)

    def __post_init__(self):
        self.windows = max(1, math.ceil((self.end_up - self.start_up) / BATCH_SEC - 1e-9))


class BatchBuilder:
    """Turns the CSV streams into schemaVersion 1 batches, one per 2 s window of `t_up`."""

    def __init__(self, folder: Path, plan: Plan):
        self.plan = plan
        self.streams = {name: Stream(folder / f"{name}.csv")
                        for name in [f for f, _ in COLUMNAR.values()] + ["location", "labels", "device"]}
        self._utc_offset: float | None = None  # utc_ms - t_up * 1000, from the latest row seen
        self._device = {"battery": -1.0, "thermal": "nominal", "lowPower": False}
        # Skip everything before the first window (and use it for the clock and device status), except
        # the fixes of the last STALE_FIX_MARGIN_S: the app sends those in batch 0 (iOS's cached first
        # fix, kept up to RecordingSession.staleFixMargin before the start).
        self._early_fixes: list[Row] = []
        for name, s in self.streams.items():
            for r in s.take_before(plan.start_up):
                self._note(r)
                if name == "location" and r.t_up >= plan.start_up - STALE_FIX_MARGIN_S:
                    self._early_fixes.append(r)

    def close(self) -> None:
        for s in self.streams.values():
            s.close()

    def _note(self, r: Row) -> None:
        if r.utc_ms is not None:
            self._utc_offset = r.utc_ms - r.t_up * 1000.0
        if "battery_level" in r.cols:
            self._device = {
                "battery": _round(_num(r.cols["battery_level"]), 6),
                "thermal": r.cols.get("thermal_state") or "nominal",
                "lowPower": r.cols.get("low_power") == "1",
            }

    def batches(self) -> Iterator[dict]:
        for seq in range(self.plan.windows):
            yield self.build(seq)

    def build(self, seq: int) -> dict:
        p = self.plan
        t0 = p.start_up + seq * BATCH_SEC
        t1 = min(t0 + BATCH_SEC, p.end_up) if seq == p.windows - 1 else t0 + BATCH_SEC
        rows = {name: s.take_before(t1) for name, s in self.streams.items()}
        # Clock: the first row of the window, else the last one seen before it.
        first = min((r for rs in rows.values() for r in rs[:1] if r.utc_ms is not None),
                    key=lambda r: r.t_up, default=None)
        offset = (first.utc_ms - first.t_up * 1000.0) if first else self._utc_offset
        if offset is None:
            raise ReplayError("no t_utc_ms in any stream: cannot place the trip in time")
        if seq == 0:
            rows["location"] = self._early_fixes + rows["location"]
        for rs in rows.values():
            for r in rs:
                self._note(r)
        t0_utc_ms = round(t0 * 1000.0 + offset + p.shift_ms)
        rel = lambda t: _round(t - t0, 6)  # noqa: E731

        b: dict = {
            "schemaVersion": 1, "eventType": "sensor_batch", "source": "replay",
            "sessionId": p.session_id, "deviceId": p.device_id, "batchSeq": seq,
            "t0Utc": iso_ms(t0_utc_ms), "t0Up": _round(t0, 6), "t0UtcMs": t0_utc_ms,
            "units": dict(UNITS), "fieldUnits": dict(FIELD_UNITS),
        }
        for block, (name, cols) in COLUMNAR.items():
            blk = {"t": [rel(r.t_up) for r in rows[name]]}
            for out, src in cols:
                blk[out] = [_round(_num(r.cols[src]), 6) for r in rows[name]]
            b[block] = blk
        b["location"] = [self._fix(r, offset) for r in rows["location"]]
        b["labels"] = [{"t": rel(r.t_up), "type": r.cols["type"],
                        "value": r.cols["value"] or None, "note": r.cols["note"] or None}
                       for r in rows["labels"] if r.cols.get("type")]
        b["device"] = dict(self._device)
        return b

    def _fix(self, r: Row, offset: float) -> dict:
        utc = r.utc_ms if r.utc_ms is not None else r.t_up * 1000.0 + offset
        fix = {"tUtcMs": round(utc + self.plan.shift_ms)}
        for out, src, digits in LOCATION_COLS:
            fix[out] = _round(_num(r.cols[src]), digits)
        sim = r.cols.get("is_simulated", "")
        fix["isSimulated"] = True if sim == "1" else False if sim == "0" else None
        return fix


def encode(obj: dict) -> bytes:
    """Sorted keys and compact separators, like the app (byte-identical re-sends)."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), allow_nan=False,
                      ensure_ascii=False).encode("utf-8")


def session_copies(plan: Plan, batch_count: int, end_utc_ms: float, start_utc_ms: float):
    """session.json for the Start and the Stop PUT, under the replay's identity."""
    start = copy.deepcopy(plan.meta)
    start.pop("batchCount", None)
    start.update(sessionId=plan.session_id, deviceId=plan.device_id, source="replay",
                 replayOf=plan.meta.get("sessionId"), startedAtUtc=iso_ms(start_utc_ms),
                 startUptimeSec=_round(plan.start_up, 6), endedAtUtc=None, recovered=False)
    for k in ("vehicle", "mount", "people"):
        if not isinstance(start.get(k), dict):
            start[k] = {}
    start["people"].pop("raterName", None)  # personal data stays on the phone, like the app (§6.1)
    stop = copy.deepcopy(start)
    stop.update(endedAtUtc=iso_ms(end_utc_ms), batchCount=batch_count)
    return start, stop


def make_plan(folder: Path, *, start_offset: float = 0.0, duration: float | None = None,
              device_id: str | None = None, session_id: str | None = None,
              speed: float = 1.0, now_ms: float | None = None) -> Plan:
    try:
        meta = json.loads((folder / "session.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise ReplayError(f"session.json: {e}")
    if not isinstance(meta, dict):
        raise ReplayError("session.json is not a JSON object")
    first = Stream(folder / "device_motion.csv")
    first_up = first.first.t_up if first.first else None
    first.close()
    last_up = max((v for v in (last_t_up(folder / f"{n}.csv") for n in
                               ("device_motion", "location", "labels")) if v is not None),
                  default=None)
    if first_up is None or last_up is None:
        raise ReplayError("device_motion.csv has no samples")
    start_up = meta.get("startUptimeSec")
    if not isinstance(start_up, (int, float)) or not math.isfinite(start_up) or start_up > first_up:
        start_up = first_up
    start_up += max(0.0, start_offset)
    end_up = last_up + 1e-6
    if duration is not None:
        end_up = min(end_up, start_up + duration)
    if end_up <= start_up:
        raise ReplayError(f"nothing to replay: the trip is {last_up - start_up + start_offset:.0f} s long")
    orig_dev = str(meta.get("deviceId") or "phone")
    plan = Plan(meta=meta, session_id=session_id or str(uuid.uuid4()),
                device_id=device_id or f"replay-{orig_dev}"[:64], start_up=start_up, end_up=end_up)
    # Shift: at real speed (or slower) the first window starts now. Faster, the trip is placed
    # so that it ends when its last batch is sent: no batch is ever stamped in the future (the
    # backend keeps the newest position per device, so a future time would freeze the next
    # replay on the Live page); a fast replay looks like a phone catching up after a dead zone.
    probe = BatchBuilder(folder, plan)
    try:
        b0 = probe.build(0)
    finally:
        probe.close()
    now = time.time() * 1000.0 if now_ms is None else now_ms
    trip_ms = plan.windows * BATCH_SEC * 1000.0
    behind = 1.0 if speed == 0 else max(0.0, 1.0 - 1.0 / speed)
    plan.shift_ms = now - b0["t0UtcMs"] - trip_ms * behind
    return plan


# --- Sending -------------------------------------------------------------------------------

@dataclass
class Sender:
    base_url: str
    key: str
    timeout: float = 30.0
    max_wait: float = 300.0  # give up on one request after this long of retries
    log: Callable[[str], None] = print
    sleep: Callable[[float], None] = time.sleep

    def _request(self, method: str, path: str, body: bytes, idem: str) -> tuple[int, str]:
        req = urllib.request.Request(self.base_url + path, data=gzip.compress(body), method=method)
        req.add_header("Content-Type", "application/json")
        req.add_header("Content-Encoding", "gzip")
        req.add_header("x-device-key", self.key)
        req.add_header("x-idempotency-key", idem)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")

    def send(self, method: str, path: str, body: bytes, idem: str) -> None:
        """Retries network errors, 429 and 5xx with backoff 1 → 30 s (like the app's queue).
        2xx and 409 are done; any other answer is a bug or a bad key, so stop."""
        delay, waited = 1.0, 0.0
        while True:
            try:
                status, text = self._request(method, path, body, idem)
            except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
                status, text = 0, str(getattr(e, "reason", e))
            if 200 <= status < 300 or status == 409:
                return
            if status == 401:
                raise ReplayError(f"401: device key rejected ({text.strip()[:200]})")
            if status == 403:  # a valid key that may not send as this deviceId
                raise ReplayError(f"403: {text.strip()[:300]} - use the replay key "
                                  "(add-device-key.ps1 -DeviceId replay) or --device-id replay-<this key's device ID>")
            if status == 404:
                raise ReplayError(f"404 for {self.base_url + path}: wrong --url?")
            if status not in (0, 429) and status < 500:
                raise ReplayError(f"{method} {path} [{idem}] rejected with {status}: {text.strip()[:500]}")
            if waited >= self.max_wait:
                raise ReplayError(f"{method} {path} [{idem}] still failing after {waited:.0f} s: "
                                  f"{status or 'network'} {text.strip()[:200]}")
            self.log(f"  retry in {delay:.0f} s ({status or 'network error'}: {text.strip()[:120]})")
            self.sleep(delay)
            waited += delay
            delay = min(delay * 2, 30.0)


def run(folder: Path, plan: Plan, *, sender: Sender | None, dry_run: Path | None,
        speed: float, send_stop: bool, log: Callable[[str], None] = print,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep) -> int:
    """Sends (or writes) the Start copy, every batch at its time, then the Stop copy.
    Returns the number of batches."""
    builder = BatchBuilder(folder, plan)
    start_ms = None
    end_ms = None
    sent = 0
    began = clock()
    status_every = max(1, round(30 / BATCH_SEC))

    def emit(name: str, method: str, path: str, body: bytes, idem: str) -> None:
        if len(body) > MAX_INFLATED:
            raise ReplayError(f"{name} is {len(body)} bytes, over the {MAX_INFLATED} byte limit")
        if dry_run is not None:
            (dry_run / f"{name}.json.gz").write_bytes(gzip.compress(body))
        else:
            sender.send(method, path, body, idem)

    def emit_stop() -> None:
        _, stop = session_copies(plan, sent, end_ms, start_ms)
        emit(f"{plan.session_id}_meta-stop", "PUT", f"/api/ingest/sessions/{plan.session_id}",
             encode(stop), f"{plan.session_id}:meta-stop")

    try:
        for b in builder.batches():
            seq = b["batchSeq"]
            if start_ms is None:
                start_ms = b["t0UtcMs"]
                start, _ = session_copies(plan, 0, start_ms, start_ms)
                emit(f"{plan.session_id}_meta-start", "PUT",
                     f"/api/ingest/sessions/{plan.session_id}", encode(start),
                     f"{plan.session_id}:meta-start")
            # The phone sends a batch when its window closes.
            if speed > 0 and dry_run is None:
                due = began + (seq + 1) * BATCH_SEC / speed
                wait = due - clock()
                if wait > 0:
                    sleep(wait)
            emit(f"{plan.session_id}_{seq:08d}", "POST", "/api/ingest", encode(b),
                 f"{plan.session_id}:{seq}")
            sent += 1
            end_ms = b["t0UtcMs"] + BATCH_SEC * 1000.0
            if b["location"]:
                end_ms = max(end_ms, b["location"][-1]["tUtcMs"])
            if seq % status_every == 0 or seq == plan.windows - 1:
                fix = b["location"][-1] if b["location"] else None
                where = f" {fix['lat']:.5f},{fix['lon']:.5f} {max(fix['speed'], 0) * 3.6:.0f} km/h" if fix else ""
                log(f"batch {seq + 1}/{plan.windows}  trip t={seq * BATCH_SEC:.0f} s{where}")
    except KeyboardInterrupt:
        # Close the trip with what was sent, so an aborted rehearsal doesn't stay "recording".
        if send_stop and end_ms is not None:
            log(f"stopped after {sent} batches: sending the Stop metadata (Ctrl+C again to skip)")
            emit_stop()
        raise
    finally:
        builder.close()
    if send_stop:
        emit_stop()
    return sent


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("session", type=Path, help="session folder exported from the app, or its .zip")
    ap.add_argument("--url", default=os.environ.get("REPLAY_API_URL"),
                    help="ingest base URL, e.g. https://<func>.azurewebsites.net "
                         "(default: $REPLAY_API_URL)")
    ap.add_argument("--speed", type=float, default=1.0,
                    help="1 = real time (default), 4 = four times faster, 0 = as fast as possible")
    ap.add_argument("--from", dest="start", type=float, default=0.0, metavar="SEC",
                    help="skip the first SEC seconds of the trip")
    ap.add_argument("--duration", type=float, default=None, metavar="SEC",
                    help="replay only SEC seconds")
    ap.add_argument("--device-id", default=None,
                    help="deviceId of the replay (default: replay-<original deviceId>)")
    ap.add_argument("--no-stop", action="store_true",
                    help="don't send the Stop metadata (tests a trip that ends in silence)")
    ap.add_argument("--dry-run", type=Path, default=None, metavar="DIR",
                    help="write the gzip bodies to DIR instead of sending them")
    args = ap.parse_args(argv)

    if args.speed < 0 or (args.duration is not None and args.duration <= 0):
        ap.error("--speed must be >= 0 and --duration > 0")
    sender = None
    if args.dry_run is None:
        if not args.url:
            ap.error("--url (or $REPLAY_API_URL) is required unless --dry-run")
        key = os.environ.get("REPLAY_DEVICE_KEY")
        if not key:
            if not sys.stdin.isatty():
                ap.error("set $REPLAY_DEVICE_KEY (the key from infra/scripts/add-device-key.ps1)")
            key = getpass.getpass("Device key: ").strip()
        base = args.url.rstrip("/")
        if base.endswith("/api/ingest"):
            base = base[: -len("/api/ingest")]
        sender = Sender(base, key)
    else:
        args.dry_run.mkdir(parents=True, exist_ok=True)

    try:
        with tempfile.TemporaryDirectory(prefix="replay-") as tmp:
            folder = open_session(args.session, Path(tmp))
            plan = make_plan(folder, start_offset=args.start, duration=args.duration,
                             device_id=args.device_id, speed=args.speed)
            vehicle = plan.meta.get("vehicle") or {}
            print(f"Replaying {plan.meta.get('sessionId')} ({vehicle.get('type', '?')}"
                  f"{' ' + vehicle['line'] if vehicle.get('line') else ''}), "
                  f"{plan.windows} batches = {plan.windows * BATCH_SEC / 60:.1f} min of trip"
                  f"{'' if args.speed == 1 else f' at {args.speed:g}x' if args.speed else ' as fast as possible'}")
            print(f"  as session {plan.session_id}, device {plan.device_id}")
            n = run(folder, plan, sender=sender, dry_run=args.dry_run, speed=args.speed,
                    send_stop=not args.no_stop)
    except ReplayError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nstopped" + ("" if args.no_stop else " (trip closed with the batches sent so far)"),
              file=sys.stderr)
        return 130
    where = f"written to {args.dry_run}" if args.dry_run else "sent"
    print(f"Done: {n} batches {where}{'' if args.no_stop else ' + Start/Stop metadata'}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
