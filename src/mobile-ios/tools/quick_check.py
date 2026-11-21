#!/usr/bin/env python3
"""quick_check.py: dry-run verifier for one exported SensorRecorder session folder (spec §10).

Usage:
    python3 -I tools/quick_check.py <session_folder>

Stdlib only (csv, json), Python 3.9+. Checks every CSV the app writes against the headers in
SensorRecorder/Core/SessionFiles.swift, then reports per stream: row count, median rate
(1 / median diff of t_up), max gap, gaps > 1 s, non-monotonic t_up and malformed rows.

Pass criteria (spec §10):
  - device_motion / accel_raw / gyro_raw: median rate >= 90 Hz and max gap < 0.1 s; fewer than
    2 rows is a FAIL
  - mag_raw ~50 Hz (WARN only)
  - location ~1 Hz, lat/lon valid and not 0,0, h_acc median reported; 0 rows is a FAIL
  - altimeter / heading / abs_altitude / activity / device with a header but 0 data rows: WARN
  - t_utc_ms of motion rows vs clock.csv anchors: <= 20 ms PASS, <= 100 ms WARN, > 100 ms FAIL
  - labels present (WARN if none); multi-line quoted notes are parsed with the csv module
  - rows before the session start (t_utc_ms < startedAtUtc), in every CSV: location rows up to 5 s
    early are INFO (the app keeps CoreLocation's cached first fix if <= 5 s old), older ones WARN;
    activity.csv is exempt (the current CMMotionActivity may have begun earlier); any other file
    with pre-start rows is a WARN (file, count, earliest offset)
  - stream coverage: location must span (last - first t_up) at least 50% of the
    session duration ((endedAtUtc or the last row of any stream) - startedAtUtc), else WARN;
    sessions shorter than 30 s are not checked
  - stats.durationSec (if present) vs endedAtUtc - startedAtUtc (finished sessions) or vs the last
    sensor row t_up - startUptimeSec (recovered / unfinished sessions): |diff| > 2 s is a WARN
  - session.json: WARN if not ended cleanly (endedAtUtc null), recovered, synthetic sensors,
    preflight overridden/missing, mount.handheld true or mount.rigid false (the backend excludes
    such sessions from roughness). Keys added in newer app versions (vehicle.line,
    mount.handheld, mount.seatOverAxle, people.raterPosture) are INFO when absent.
  - no audio since D48: a folder from an older build may still hold audio_level.csv,
    audio_segments.csv, audio_*.m4a / audio.m4a, clock.csv rows with source=audio_start and
    session.json audioEnabled / requestedRatesHz.audioLevel / stats.audioFiles /
    stats.audioFilesIncomplete. They are not checked: one INFO line lists what was found.

A check that hits unexpected data (wrong header, unreadable file, ...) becomes a FAIL line for
that file; the remaining checks still run and the summary is always printed.

Prints a final line "OVERALL: PASS|WARN|FAIL". Exit code 0 for PASS/WARN, 1 for FAIL, 2 for usage.
"""

import bisect
import csv
import datetime as dt
import json
import math
import os
import statistics
import sys

# Exact headers written by the app (SessionFiles.swift, StreamFile.header). Source of truth.
COMMON = ["t_up", "t_utc_ms"]
EXPECTED_HEADERS = {
    "device_motion": COMMON + ["ua_x", "ua_y", "ua_z", "g_x", "g_y", "g_z", "rr_x", "rr_y", "rr_z",
                               "q_w", "q_x", "q_y", "q_z", "roll", "pitch", "yaw"],
    "accel_raw": COMMON + ["x", "y", "z"],
    "gyro_raw": COMMON + ["x", "y", "z"],
    "mag_raw": COMMON + ["x", "y", "z"],
    "location": COMMON + ["lat", "lon", "alt", "ell_alt", "h_acc", "v_acc", "speed", "speed_acc",
                          "course", "course_acc", "is_simulated"],
    "heading": COMMON + ["mag_heading", "true_heading", "heading_acc", "x", "y", "z"],
    "altimeter": COMMON + ["rel_alt_m", "pressure_kpa"],
    "abs_altitude": COMMON + ["altitude_m", "accuracy_m", "precision_m"],
    "activity": COMMON + ["stationary", "walking", "running", "automotive", "cycling", "unknown",
                          "confidence", "start_utc_ms"],
    "device": COMMON + ["battery_level", "battery_state", "thermal_state", "low_power",
                        "free_disk_bytes", "net_status", "net_type"],
    "labels": COMMON + ["type", "value", "note"],
    "clock": COMMON + ["source"],
}
# Files only app builds before D48 (no audio) wrote. StreamFile keeps their headers so old sessions
# still parse; quick_check never reads them (check_legacy_files only reports that they are there).
LEGACY_HEADERS = {
    "audio_level": COMMON + ["avg_dbfs", "peak_dbfs"],
    "audio_segments": COMMON + ["event", "file"],
}
LEGACY_CLOCK_SOURCES = ("audio_start",)  # derived from the current anchor, not a clock read
# Both schemas as exact header lines, keyed by file stem (StreamFile.rawValue). test_tools.py pins it
# against tools/fixtures/csv_headers.json, which the Swift unit tests write from StreamFile.header.
EXPECTED_HEADER_LINES = {name: ",".join(cols)
                         for name, cols in {**EXPECTED_HEADERS, **LEGACY_HEADERS}.items()}

# Rate-checked streams: (min_hz, max_gap_s, severity_if_violated, missing_severity)
MOTION = ("device_motion", "accel_raw", "gyro_raw")
RATE_RULES = {
    "device_motion": (90.0, 0.1, "FAIL", "FAIL"),
    "accel_raw": (90.0, 0.1, "FAIL", "FAIL"),
    "gyro_raw": (90.0, 0.1, "FAIL", "FAIL"),
    "mag_raw": (45.0, 0.2, "WARN", "WARN"),
}
# Order of the per-stream table; anything not in RATE_RULES is informational only.
STREAM_ORDER = ["device_motion", "accel_raw", "gyro_raw", "mag_raw", "location", "heading",
                "altimeter", "abs_altitude", "activity", "device"]
MISSING_SEVERITY = {"location": "FAIL", "clock": "FAIL", "labels": "WARN"}
# Slow / event-driven streams: a header with 0 data rows means the sensor never delivered (no
# barometer on the Simulator, permission denied, ...). Worth a WARN, not a silent PASS.
ZERO_ROW_WARN = ("heading", "altimeter", "abs_altitude", "activity", "device")

UTC_DEV_OK_MS = 20.0     # max |t_utc_ms - anchor-derived utc| considered fine (PASS)
UTC_DEV_FAIL_MS = 100.0  # beyond this the time base is broken (FAIL); in between WARN

# Rows before session start. startedAtUtc and t_utc_ms are both millisecond-rounded renderings of
# the start anchor, so 1 ms of slack avoids flagging the start anchor itself.
PRESTART_ROUNDING_MS = 1.0
LOCATION_PRESTART_OK_MS = 5000.0  # RecordingSession.staleFixMargin: cached first fix kept if <= 5 s old
PRESTART_EXEMPT = ("activity",)   # the current CMMotionActivity may have started before the session

COVERAGE_STREAMS = ("location",)
COVERAGE_MIN_FRACTION = 0.5    # stream span must cover at least this share of the session
COVERAGE_MIN_SESSION_S = 30.0  # shorter sessions are not coverage-checked
DURATION_TOLERANCE_S = 2.0     # stats.durationSec vs. timestamps

RATER_POSTURES = ("seated", "standing")
RANK = {"PASS": 0, "WARN": 1, "FAIL": 2}


class Report:
    def __init__(self):
        self.issues = []  # (severity, message), severity in WARN/FAIL
        self.infos = []

    def add(self, severity, msg):
        self.issues.append((severity, msg))
        print(f"  [{severity}] {msg}")

    def info(self, msg):
        self.infos.append(msg)
        print(f"  [INFO] {msg}")

    def ok(self, msg):
        print(f"  [PASS] {msg}")

    @property
    def overall(self):
        worst = "PASS"
        for sev, _ in self.issues:
            if RANK[sev] > RANK[worst]:
                worst = sev
        return worst


def guarded(rep, label, fn, *args, default=None):
    """Run one check; any unexpected exception becomes a FAIL line for `label` instead of a crash."""
    try:
        return fn(*args)
    except Exception as e:  # noqa: BLE001 - the verifier must never crash on odd input
        detail = f"missing column/key {e.args[0]!r}" if isinstance(e, KeyError) and e.args else \
            f"{type(e).__name__}: {e}"
        rep.add("FAIL", f"{label}: could not be checked ({detail})")
        return default


def fnum(s):
    """Parse a float; empty / invalid / non-finite -> None (the app writes NaN as an empty field)."""
    try:
        v = float(s)
    except (TypeError, ValueError):
        return None
    return v if math.isfinite(v) else None


def human_utc(ms):
    if ms is None:
        return "n/a"
    try:
        return dt.datetime.fromtimestamp(ms / 1000.0, tz=dt.timezone.utc).strftime(
            "%Y-%m-%d %H:%M:%S.%f")[:-3] + "Z"
    except (OverflowError, OSError, ValueError):
        return f"<invalid {ms}>"


def read_csv(path, name, rep):
    """Read a CSV with the csv module (handles quoted fields with commas/newlines).
    Validates the header and per-row column count. Returns (header, [(line_no, row), ...]) with
    only well-formed rows; header is None for an empty file."""
    header, rows = None, []
    with open(path, newline="", encoding="utf-8", errors="replace") as fh:
        reader = csv.reader(fh)
        try:
            header = next(reader, None)
            for row in reader:
                if not row:  # skip blank lines
                    continue
                rows.append((reader.line_num, row))
        except csv.Error as e:
            rep.add("FAIL", f"{name}.csv: CSV parse error near line {reader.line_num}: {e} "
                            f"({len(rows)} rows read before it)")
    expected = EXPECTED_HEADERS.get(name)
    if header is None:
        rep.add("FAIL", f"{name}.csv: empty file (no header)")
        return None, []
    if expected is not None and header != expected:
        rep.add("FAIL", f"{name}.csv: header mismatch\n         got:      {','.join(header)}"
                        f"\n         expected: {','.join(expected)}")
    ncol = len(header)
    bad = [(ln, len(r)) for ln, r in rows if len(r) != ncol]
    if bad:
        only_last = len(bad) == 1 and rows and bad[0][0] == rows[-1][0]
        if only_last:
            rep.add("WARN", f"{name}.csv: last row truncated ({bad[0][1]} cols, expected {ncol}) "
                            f"- typical after a crash; ignored")
        else:
            rep.add("FAIL", f"{name}.csv: {len(bad)} rows with wrong column count "
                            f"(expected {ncol}; first at line {bad[0][0]} has {bad[0][1]})")
    good = [(ln, r) for ln, r in rows if len(r) == ncol]
    return header, good


def require_columns(name, idx, cols, rep):
    """FAIL (named) if any column needed for a semantic check is absent; returns True if all present."""
    missing = [c for c in cols if c not in idx]
    if missing:
        rep.add("FAIL", f"{name}.csv: cannot check contents, column(s) missing: {', '.join(missing)}")
        return False
    return True


def timing_stats(tups):
    """tups: list of t_up floats in file order."""
    n = len(tups)
    out = {"rows": n, "rate": None, "max_gap": None, "gaps_1s": 0, "nonmono": 0}
    if n < 2:
        return out
    diffs = [b - a for a, b in zip(tups, tups[1:])]
    out["nonmono"] = sum(1 for d in diffs if d <= 0)
    pos = [d for d in diffs if d > 0]
    if pos:
        med = statistics.median(pos)
        out["rate"] = 1.0 / med if med > 0 else None
    out["max_gap"] = max(diffs)
    out["gaps_1s"] = sum(1 for d in diffs if d > 1.0)
    return out


def load_clock(folder, rep):
    """Returns sorted anchors [(up, utc_ms)] from clock.csv (pre-D48 derived rows excluded)."""
    path = os.path.join(folder, "clock.csv")
    print("\n== clock.csv ==")
    if not os.path.exists(path):
        rep.add("FAIL", "MISSING clock.csv - cannot verify t_utc_ms")
        return []
    header, rows = read_csv(path, "clock", rep)
    if header is None:
        return []
    idx = {h: i for i, h in enumerate(header)}
    anchors, sources = [], {}
    for _, r in rows:
        src = r[idx["source"]] if "source" in idx else "?"
        sources[src] = sources.get(src, 0) + 1
        if src in LEGACY_CLOCK_SOURCES:
            continue  # reported by check_legacy_files
        up, utc = fnum(r[idx.get("t_up", 0)]), fnum(r[idx.get("t_utc_ms", 1)])
        if up is not None and utc is not None:
            anchors.append((up, utc))
    print("  sources: " + ", ".join(f"{k}={v}" for k, v in sorted(sources.items())))
    anchors.sort()
    if not anchors:
        rep.add("FAIL", "clock.csv has no usable anchors")
        return []
    if "start" not in sources:
        rep.add("WARN", "clock.csv has no 'start' anchor")
    gaps = [b[0] - a[0] for a, b in zip(anchors, anchors[1:])]
    if gaps:
        print(f"  anchors={len(anchors)} median spacing={statistics.median(gaps):.1f}s "
              f"max spacing={max(gaps):.1f}s")
        # Wall-clock vs uptime drift between consecutive anchors (NTP steps show up here).
        drift = max(abs((b[1] - a[1]) - (b[0] - a[0]) * 1000.0) for a, b in zip(anchors, anchors[1:]))
        print(f"  max wall-clock step between anchors: {drift:.1f} ms")
        if drift > 1000:
            rep.add("WARN", f"wall clock jumped {drift:.0f} ms between two anchors (NTP/manual change?)")
        if max(gaps) > 30:
            rep.add("WARN", f"clock anchors up to {max(gaps):.0f}s apart (expected every 10 s)")
    print(f"  first anchor: {human_utc(anchors[0][1])}   last anchor: {human_utc(anchors[-1][1])}")
    return anchors


def utc_deviation(anchors, tups, utcs):
    """Max |t_utc_ms - predicted| using (a) the nearest anchor (spec §5) and (b) the better of the two
    adjacent anchors (the app converts with the latest anchor at write time)."""
    if not anchors:
        return None, None
    ups = [a[0] for a in anchors]
    max_near = max_best = 0.0
    for t, u in zip(tups, utcs):
        if t is None or u is None:
            continue
        i = bisect.bisect_left(ups, t)
        cands = []
        if i > 0:
            cands.append(anchors[i - 1])
        if i < len(anchors):
            cands.append(anchors[i])
        devs = [(abs(t - a[0]), abs(u - (a[1] + (t - a[0]) * 1000.0))) for a in cands]
        near = min(devs)[1]
        best = min(d for _, d in devs)
        max_near = max(max_near, near)
        max_best = max(max_best, best)
    return max_near, max_best


def check_streams(folder, rep, anchors):
    print("\n== sensor streams ==")
    print(f"  {'stream':14s} {'rows':>8s} {'rate':>9s} {'max_gap':>9s} {'gaps>1s':>7s} {'nonmono':>7s}")
    span = [None, None]  # overall t_up span of motion data, for label sanity
    utc_firstlast = {}
    times = {}  # stem -> ([valid t_up], [valid t_utc_ms]) in file order, for the timeline checks
    for name in STREAM_ORDER:
        guarded(rep, f"{name}.csv", check_one_stream, folder, name, rep, anchors, span, utc_firstlast,
                times)
    return span, utc_firstlast, times


def check_one_stream(folder, name, rep, anchors, span, utc_firstlast, times):
    path = os.path.join(folder, f"{name}.csv")
    if not os.path.exists(path):
        sev = RATE_RULES[name][3] if name in RATE_RULES else MISSING_SEVERITY.get(name, "WARN")
        print(f"  {name:14s} MISSING")
        rep.add(sev, f"MISSING {name}.csv")
        return
    header, rows = read_csv(path, name, rep)
    if header is None:
        return
    idx = {h: i for i, h in enumerate(header)}
    it, iu = idx.get("t_up", 0), idx.get("t_utc_ms", 1)
    tups_all = [fnum(r[it]) for _, r in rows]
    utcs_all = [fnum(r[iu]) for _, r in rows]
    bad_t = sum(1 for t in tups_all if t is None)
    tups = [t for t in tups_all if t is not None]
    st = timing_stats(tups)
    rate = f"{st['rate']:7.2f}Hz" if st["rate"] else "      n/a"
    gap = f"{st['max_gap']:8.3f}s" if st["max_gap"] is not None else "      n/a"
    print(f"  {name:14s} {st['rows']:8d} {rate:>9s} {gap:>9s} {st['gaps_1s']:7d} {st['nonmono']:7d}")
    if bad_t:
        rep.add("WARN", f"{name}: {bad_t} rows with empty/invalid t_up")
    if st["nonmono"]:
        rep.add("FAIL" if name in MOTION else "WARN",
                f"{name}: {st['nonmono']} non-monotonic t_up steps")
    valid_utc = [u for u in utcs_all if u is not None]
    times[name] = (tups, valid_utc)
    if valid_utc:
        utc_firstlast[name] = (valid_utc[0], valid_utc[-1])

    if name in ZERO_ROW_WARN and not rows:
        rep.add("WARN", f"{name}.csv: header only, 0 data rows (sensor never delivered)")

    if name in RATE_RULES:
        min_hz, max_gap, sev, _ = RATE_RULES[name]
        if st["rows"] < 2:
            rep.add(sev, f"{name}: only {st['rows']} data rows")
        else:
            problems = []
            if st["rate"] is None or st["rate"] < min_hz:
                problems.append(f"median rate {st['rate'] or 0:.1f} Hz < {min_hz:.0f} Hz")
            if st["max_gap"] >= max_gap:
                problems.append(f"max gap {st['max_gap']:.3f}s >= {max_gap}s "
                                f"({st['gaps_1s']} gaps > 1 s)")
            if problems:
                rep.add(sev, f"{name}: " + "; ".join(problems))
            else:
                rep.ok(f"{name}: {st['rate']:.1f} Hz, max gap {st['max_gap']:.3f}s")

    if name in MOTION and tups:
        span[0] = tups[0] if span[0] is None else min(span[0], tups[0])
        span[1] = tups[-1] if span[1] is None else max(span[1], tups[-1])
        near, best = utc_deviation(anchors, tups_all, utcs_all)
        if near is None:
            rep.add("WARN", f"{name}: t_utc_ms not verifiable (no clock anchors)")
        elif not valid_utc:
            rep.add("FAIL", f"{name}: no valid t_utc_ms values")
        else:
            msg = (f"{name}: t_utc_ms vs clock anchors max |dev| = {near:.1f} ms nearest-anchor, "
                   f"{best:.1f} ms best-adjacent-anchor (PASS <= {UTC_DEV_OK_MS:.0f} ms, "
                   f"FAIL > {UTC_DEV_FAIL_MS:.0f} ms)")
            if best > UTC_DEV_FAIL_MS:
                rep.add("FAIL", msg)
            elif best > UTC_DEV_OK_MS:
                rep.add("WARN", msg)
            else:
                rep.ok(msg)

    if name == "location":
        check_location(rows, idx, st, rep)


def check_location(rows, idx, st, rep):
    if st["rows"] == 0:
        rep.add("FAIL", "location: 0 rows (no GPS fix)")
        return
    if not require_columns("location", idx, ("lat", "lon", "h_acc", "is_simulated"), rep):
        return
    bad, sim, hacc = 0, 0, []
    for _, r in rows:
        lat, lon = fnum(r[idx["lat"]]), fnum(r[idx["lon"]])
        if (lat is None or lon is None or not (-90 <= lat <= 90) or not (-180 <= lon <= 180)
                or (abs(lat) < 1e-9 and abs(lon) < 1e-9)):
            bad += 1
        h = fnum(r[idx["h_acc"]])
        if h is not None and h >= 0:
            hacc.append(h)
        if r[idx["is_simulated"]].strip() == "1":
            sim += 1
    first = rows[0][1]
    print(f"  location: first fix lat={first[idx['lat']]} lon={first[idx['lon']]}, "
          f"h_acc median={statistics.median(hacc) if hacc else float('nan'):.1f} m")
    if bad:
        rep.add("FAIL" if bad > 0.01 * st["rows"] else "WARN",
                f"location: {bad}/{st['rows']} rows with invalid lat/lon or 0,0")
    if sim:
        rep.add("WARN", f"location: {sim} rows flagged is_simulated=1")
    if hacc and statistics.median(hacc) > 20:
        rep.add("WARN", f"location: median h_acc {statistics.median(hacc):.1f} m is poor (> 20 m)")
    if st["rate"] is not None and not (0.5 <= st["rate"] <= 2.0):
        rep.add("WARN", f"location: median rate {st['rate']:.2f} Hz (expected ~1 Hz)")
    elif st["rate"] is not None and not bad:
        rep.ok(f"location: {st['rate']:.2f} Hz, coordinates valid")


def check_utc_realtime(utc_firstlast, meta, rep):
    print("\n== real-time check (confirm these are the actual recording times) ==")
    for name in MOTION + ("location",):
        if name in utc_firstlast:
            a, b = utc_firstlast[name]
            print(f"  {name:14s} first={human_utc(a)}  last={human_utc(b)}  ({(b - a) / 1000:.1f}s)")
    lo = dt.datetime(2024, 1, 1, tzinfo=dt.timezone.utc).timestamp() * 1000
    hi = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=1)).timestamp() * 1000
    for name, (a, b) in utc_firstlast.items():
        if not (lo <= a <= hi and lo <= b <= hi):
            rep.add("FAIL", f"{name}: t_utc_ms outside plausible range ({human_utc(a)} .. {human_utc(b)})")
    started = parse_iso(meta.get("startedAtUtc")) if isinstance(meta, dict) else None
    if started is not None and "device_motion" in utc_firstlast:
        d = (utc_firstlast["device_motion"][0] - started) / 1000.0
        print(f"  first device_motion sample is {d:+.1f}s after session.json startedAtUtc")
        if abs(d) > 120:
            rep.add("WARN", f"first motion sample {d:+.0f}s from startedAtUtc")


def parse_iso(s):
    if not isinstance(s, str) or not s:
        return None
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() * 1000
    except ValueError:
        return None


def scan_times(path):
    """Quietly read (t_up, t_utc_ms) of a CSV (header/row problems are reported by the main checks).
    Returns ([valid t_up], [valid t_utc_ms]) in file order; only rows with the header's width."""
    tups, utcs = [], []
    with open(path, newline="", encoding="utf-8", errors="replace") as fh:
        reader = csv.reader(fh)
        try:
            header = next(reader, None)
            if not header or "t_up" not in header or "t_utc_ms" not in header:
                return tups, utcs
            it, iu, ncol = header.index("t_up"), header.index("t_utc_ms"), len(header)
            for row in reader:
                if len(row) != ncol:
                    continue
                t, u = fnum(row[it]), fnum(row[iu])
                if t is not None:
                    tups.append(t)
                if u is not None:
                    utcs.append(u)
        except csv.Error:
            pass  # already a FAIL from read_csv; keep what was read
    return tups, utcs


def check_timeline(folder, meta, times, rep):
    """Rows before the session start, stream coverage and stats.durationSec (all need session.json)."""
    print("\n== session timeline ==")
    if not isinstance(meta, dict):
        print("  session.json unavailable - timeline checks skipped")
        return
    for name in EXPECTED_HEADERS:  # labels / clock are not in the stream table
        path = os.path.join(folder, f"{name}.csv")
        if name not in times and os.path.exists(path):
            times[name] = guarded(rep, f"{name}.csv", scan_times, path, default=([], []))
    start = parse_iso(meta.get("startedAtUtc"))
    if start is None:
        rep.add("WARN", "session.json: startedAtUtc missing/invalid - timeline checks skipped")
        return
    guarded(rep, "rows before session start", check_prestart_rows, start, times, rep)
    guarded(rep, "stream coverage", check_coverage, meta, start, times, rep)
    guarded(rep, "stats.durationSec", check_duration, meta, start, times, rep)


def check_prestart_rows(start, times, rep):
    found = False
    for name in EXPECTED_HEADERS:
        if name not in times:
            continue
        pre = [u for u in times[name][1] if u < start - PRESTART_ROUNDING_MS]
        if not pre:
            continue
        found = True
        earliest = (min(pre) - start) / 1000.0
        if name in PRESTART_EXEMPT:
            print(f"  {name}.csv: {len(pre)} row(s) before session start (earliest {earliest:+.1f} s) "
                  f"- expected, the current activity began earlier")
        elif name == "location":
            old = [u for u in pre if u < start - LOCATION_PRESTART_OK_MS]
            recent = len(pre) - len(old)
            if recent:
                rep.info(f"location.csv: {recent} row(s) up to {LOCATION_PRESTART_OK_MS / 1000:.0f} s "
                         f"before session start (cached first fix, expected)")
            if old:
                rep.add("WARN", f"location.csv: {len(old)} row(s) more than "
                                f"{LOCATION_PRESTART_OK_MS / 1000:.0f} s before session start "
                                f"(earliest {(min(old) - start) / 1000.0:+.1f} s)")
        else:
            rep.add("WARN", f"{name}.csv: {len(pre)} row(s) before session start "
                            f"(earliest {earliest:+.1f} s)")
    if not found:
        rep.ok("no rows before session start")


def check_coverage(meta, start, times, rep):
    end = parse_iso(meta.get("endedAtUtc"))
    basis = "endedAtUtc"
    if end is None:
        lasts = [max(u) for _, u in times.values() if u]
        if not lasts:
            print("  session duration unknown (no endedAtUtc, no rows) - coverage not checked")
            return
        end, basis = max(lasts), "last row"
    dur = (end - start) / 1000.0
    print(f"  session duration: {dur:.1f} s (startedAtUtc .. {basis})")
    if dur < COVERAGE_MIN_SESSION_S:
        print(f"  session shorter than {COVERAGE_MIN_SESSION_S:.0f} s - coverage not checked")
        return
    for name in COVERAGE_STREAMS:
        tups = times.get(name, ([], []))[0]
        if not tups:
            continue  # missing / 0 rows is reported by the stream checks
        span = max(tups) - min(tups)
        if span < COVERAGE_MIN_FRACTION * dur:
            rep.add("WARN", f"{name} covers only {span:.0f} s of {dur:.0f} s session")
        else:
            rep.ok(f"{name} covers {span:.0f} s of {dur:.0f} s session")


def check_duration(meta, start, times, rep):
    stats = meta.get("stats")
    d = fnum(stats.get("durationSec")) if isinstance(stats, dict) else None
    if d is None:
        print("  stats.durationSec: (absent)")
        return
    if meta.get("recovered") or meta.get("endedAtUtc") is None:
        su = fnum(meta.get("startUptimeSec"))
        lasts = [max(times[n][0]) for n in STREAM_ORDER if n in times and times[n][0]]
        if su is None or su <= 0 or not lasts:
            print(f"  stats.durationSec={d:.1f} s not verifiable (no startUptimeSec / sensor rows)")
            return
        ref, basis = max(lasts) - su, "last row t_up - startUptimeSec"
    else:
        end = parse_iso(meta.get("endedAtUtc"))
        if end is None:
            rep.add("WARN", f"session.json: endedAtUtc {meta.get('endedAtUtc')!r} is not a valid date")
            return
        ref, basis = (end - start) / 1000.0, "endedAtUtc - startedAtUtc"
    diff = d - ref
    msg = f"session.json: stats.durationSec {d:.1f} s vs {basis} {ref:.1f} s (diff {diff:+.1f} s)"
    if abs(diff) > DURATION_TOLERANCE_S:
        rep.add("WARN", msg)
    else:
        rep.ok(msg)


def check_labels(folder, rep, span):
    print("\n== labels.csv ==")
    path = os.path.join(folder, "labels.csv")
    if not os.path.exists(path):
        rep.add("WARN", "MISSING labels.csv")
        return
    # csv module: a note with commas/newlines is one quoted field, so a multi-line note counts once.
    header, rows = read_csv(path, "labels", rep)
    if header is None:
        return
    idx = {h: i for i, h in enumerate(header)}
    if not require_columns("labels", idx, ("t_up", "type"), rep):
        return
    counts = {}
    outside = 0
    for _, r in rows:
        typ = r[idx["type"]]
        counts[typ] = counts.get(typ, 0) + 1
        t = fnum(r[idx["t_up"]])
        if span[0] is not None and t is not None and not (span[0] - 5 <= t <= span[1] + 5):
            outside += 1
    print(f"  rows={len(rows)}  " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    if not rows:
        # The app has no label buttons since D51: a new trip never has labels.
        rep.info("labels.csv has no labels (expected since D51: the app records none)")
    else:
        rep.ok(f"{len(rows)} labels")
    if outside:
        rep.add("WARN", f"labels: {outside} labels have t_up outside the motion data time span")


def check_legacy_files(folder, meta, rep):
    """Pre-D48 audio data (older app builds): not checked, one INFO line lists what is there."""
    found = sorted(f for f in os.listdir(folder)
                   if (f.startswith("audio_") and f.endswith(".m4a")) or f == "audio.m4a")
    found += [f"{name}.csv" for name in LEGACY_HEADERS
              if os.path.exists(os.path.join(folder, f"{name}.csv"))]
    clock_path = os.path.join(folder, "clock.csv")
    if os.path.exists(clock_path):
        with open(clock_path, newline="", encoding="utf-8", errors="replace") as fh:
            try:
                n = sum(1 for r in csv.DictReader(fh) if r.get("source") in LEGACY_CLOCK_SOURCES)
            except csv.Error:
                n = 0  # already a FAIL from load_clock
        if n:
            found.append(f"{n} clock.csv row(s) with source={'/'.join(LEGACY_CLOCK_SOURCES)}")
    if isinstance(meta, dict):
        rates, stats = _obj(meta, "requestedRatesHz"), _obj(meta, "stats")
        found += [f"session.json {label}" for present, label in (
            ("audioEnabled" in meta, "audioEnabled"),
            ("audioLevel" in rates, "requestedRatesHz.audioLevel"),
            ("audioFiles" in stats, "stats.audioFiles"),
            ("audioFilesIncomplete" in stats, "stats.audioFilesIncomplete")) if present]
    if found:
        print("\n== pre-D48 files ==")
        rep.info(f"from an app build before D48 (no audio), ignored: {', '.join(found)}")


def _obj(meta, key):
    v = meta.get(key)
    return v if isinstance(v, dict) else {}


def check_session_fields(meta, rep):
    """Vehicle / mount / people fields. Keys added in newer app versions are INFO if absent."""
    vehicle, mount, people = _obj(meta, "vehicle"), _obj(meta, "mount"), _obj(meta, "people")

    def show(label, container, key, newer):
        present = key in container
        val = container.get(key)
        print(f"  {label:21s}: {json.dumps(val) if present else '(absent)'}")
        if not present and newer:
            rep.info(f"session.json: no {label} (older app version)")
        return present, val

    show("vehicle.type", vehicle, "type", False)
    has_line, line = show("vehicle.line", vehicle, "line", True)
    show("mount.rigid", mount, "rigid", False)
    has_hand, handheld = show("mount.handheld", mount, "handheld", True)
    has_axle, axle = show("mount.seatOverAxle", mount, "seatOverAxle", True)
    has_post, posture = show("people.raterPosture", people, "raterPosture", True)

    if has_line and line is not None and not isinstance(line, str):
        rep.add("WARN", f"session.json: vehicle.line should be a string or null, got {line!r}")
    if vehicle.get("type") in ("bus", "tram") and not line:
        rep.info("session.json: public-transport session without a line number")
    for present, val, label in ((has_hand, handheld, "mount.handheld"),
                                (has_axle, axle, "mount.seatOverAxle")):
        if present and not isinstance(val, bool):
            rep.add("WARN", f"session.json: {label} should be true/false, got {val!r}")
    if has_post and posture not in RATER_POSTURES:
        rep.add("WARN", f"session.json: people.raterPosture should be one of "
                        f"{'/'.join(RATER_POSTURES)}, got {posture!r}")
    if handheld is True:
        rep.add("WARN", "session.json: mount.handheld=true - excluded from roughness by the backend")
    if mount.get("rigid") is False:
        rep.add("WARN", "session.json: mount.rigid=false - excluded from roughness by the backend")


def check_session_json(folder, rep):
    print("\n== session.json ==")
    path = os.path.join(folder, "session.json")
    if not os.path.exists(path):
        rep.add("FAIL", "MISSING session.json")
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            meta = json.load(fh)
    except (OSError, ValueError) as e:
        rep.add("FAIL", f"session.json unreadable: {e}")
        return None
    if not isinstance(meta, dict):
        rep.add("FAIL", "session.json is not a JSON object")
        return None
    pre = _obj(meta, "preflight")
    print(f"  sessionId            : {meta.get('sessionId')}")
    print(f"  startedAtUtc         : {meta.get('startedAtUtc')}")
    print(f"  endedAtUtc           : {meta.get('endedAtUtc')}")
    print(f"  recovered            : {meta.get('recovered')}")
    print(f"  syntheticSensors     : {meta.get('syntheticSensors')}")
    print(f"  preflight.overridden : {pre.get('overridden') if pre else '(no preflight)'}")
    if not meta.get("sessionId"):
        rep.add("FAIL", "session.json: missing sessionId")
    if meta.get("endedAtUtc") is None:
        rep.add("WARN", "session.json: endedAtUtc is null - session was not stopped cleanly "
                        "(recovered/unfinished)")
    if meta.get("recovered"):
        rep.add("WARN", f"session.json: recovered=true (recoveredAtUtc={meta.get('recoveredAtUtc')})")
    if meta.get("syntheticSensors"):
        print("\n  " + "!" * 72)
        print("  !!  WARNING: syntheticSensors = true                                  !!")
        print("  !!  This session contains SIMULATED sensor data, not real recordings. !!")
        print("  !!  Do NOT use it as drive data.                                      !!")
        print("  " + "!" * 72 + "\n")
        rep.add("WARN", "session.json: syntheticSensors=true (SIMULATED DATA)")
    if pre.get("overridden"):
        rep.add("WARN", "session.json: preflight was overridden")
    elif not pre:
        rep.add("WARN", "session.json: no preflight record")
    guarded(rep, "session.json fields", check_session_fields, meta, rep)
    return meta


def main(argv):
    if len(argv) != 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0 if len(argv) == 2 else 2
    try:  # never die on a console that cannot print the em dash / non-ASCII notes
        sys.stdout.reconfigure(errors="replace")
    except (AttributeError, ValueError):
        pass
    folder = argv[1]
    if not os.path.isdir(folder):
        print(f"not a directory: {folder}")
        return 2
    print(f"Session folder: {os.path.abspath(folder)}")
    rep = Report()
    meta = guarded(rep, "session.json", check_session_json, folder, rep)
    anchors = guarded(rep, "clock.csv", load_clock, folder, rep, default=[])
    span, utc_firstlast, times = guarded(rep, "sensor streams", check_streams, folder, rep, anchors,
                                         default=([None, None], {}, {}))
    guarded(rep, "real-time check", check_utc_realtime, utc_firstlast, meta, rep)
    guarded(rep, "session timeline", check_timeline, folder, meta, times, rep)
    guarded(rep, "labels.csv", check_labels, folder, rep, span)
    guarded(rep, "pre-D48 files", check_legacy_files, folder, meta, rep)

    overall = rep.overall
    print("\n== summary ==")
    for sev in ("FAIL", "WARN"):
        for s, msg in rep.issues:
            if s == sev:
                print(f"  {sev}: {msg.splitlines()[0]}")
    for msg in rep.infos:
        print(f"  INFO: {msg}")
    n_fail = sum(1 for s, _ in rep.issues if s == "FAIL")
    n_warn = sum(1 for s, _ in rep.issues if s == "WARN")
    print(f"OVERALL: {overall}  ({n_fail} fail, {n_warn} warn)")
    return 1 if overall == "FAIL" else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
