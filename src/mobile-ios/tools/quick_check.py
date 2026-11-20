#!/usr/bin/env python3
"""quick_check.py: dry-run verifier for one exported SensorRecorder session folder (spec §10).

Usage:
    python3 tools/quick_check.py <session_folder>

Stdlib only (csv, json). Checks every CSV the app writes against the headers in
SensorRecorder/Core/SessionFiles.swift, then reports per stream: row count, median rate
(1 / median diff of t_up), max gap, gaps > 1 s, non-monotonic t_up and malformed rows.

Pass criteria (spec §10):
  - device_motion / accel_raw / gyro_raw: median rate >= 90 Hz and max gap < 0.1 s  (else FAIL)
  - mag_raw ~50 Hz (WARN only), audio_level ~10 Hz (WARN only)
  - location ~1 Hz, lat/lon valid and not 0,0, h_acc median reported
  - t_utc_ms of motion rows agrees with clock.csv anchors to within a few ms
  - labels present, audio segments present and consistent with audio_segments.csv
  - session.json sane (ended, not recovered, not synthetic, preflight not overridden)

Prints a final line "OVERALL: PASS|WARN|FAIL". Exit code 0 for PASS/WARN, 1 for FAIL.
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
    "audio_level": COMMON + ["avg_dbfs", "peak_dbfs"],
    "audio_segments": COMMON + ["event", "file"],
    "device": COMMON + ["battery_level", "battery_state", "thermal_state", "low_power",
                        "free_disk_bytes", "net_status", "net_type"],
    "labels": COMMON + ["type", "value", "note"],
    "clock": COMMON + ["source"],
}

# Rate-checked streams: (min_hz, max_gap_s, severity_if_violated, missing_severity)
MOTION = ("device_motion", "accel_raw", "gyro_raw")
RATE_RULES = {
    "device_motion": (90.0, 0.1, "FAIL", "FAIL"),
    "accel_raw": (90.0, 0.1, "FAIL", "FAIL"),
    "gyro_raw": (90.0, 0.1, "FAIL", "FAIL"),
    "mag_raw": (45.0, 0.2, "WARN", "WARN"),
    "audio_level": (8.0, 1.0, "WARN", "WARN"),
}
# Order of the per-stream table; anything not in RATE_RULES is informational only.
STREAM_ORDER = ["device_motion", "accel_raw", "gyro_raw", "mag_raw", "location", "heading",
                "altimeter", "abs_altitude", "activity", "audio_level", "device"]
MISSING_SEVERITY = {"location": "FAIL", "clock": "FAIL", "labels": "WARN"}

UTC_DEV_OK_MS = 20.0      # max |t_utc_ms - anchor-derived utc| considered fine
UTC_DEV_FAIL_MS = 1000.0  # beyond this the time base is broken

RANK = {"PASS": 0, "WARN": 1, "FAIL": 2}


class Report:
    def __init__(self):
        self.issues = []  # (severity, message)

    def add(self, severity, msg):
        self.issues.append((severity, msg))
        print(f"  [{severity}] {msg}")

    def ok(self, msg):
        print(f"  [PASS] {msg}")

    @property
    def overall(self):
        worst = "PASS"
        for sev, _ in self.issues:
            if RANK[sev] > RANK[worst]:
                worst = sev
        return worst


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
    with open(path, newline="", encoding="utf-8", errors="replace") as fh:
        reader = csv.reader(fh)
        header = next(reader, None)
        rows = []
        for row in reader:
            if not row:  # skip blank lines
                continue
            rows.append((reader.line_num, row))
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
    """Returns sorted anchors [(up, utc_ms)] from clock.csv (excluding derived audio_start rows)."""
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
        if src == "audio_start":
            continue  # derived from the current anchor, not an independent clock read
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
    for name in STREAM_ORDER:
        path = os.path.join(folder, f"{name}.csv")
        if not os.path.exists(path):
            sev = RATE_RULES[name][3] if name in RATE_RULES else MISSING_SEVERITY.get(name, "WARN")
            print(f"  {name:14s} MISSING")
            rep.add(sev, f"MISSING {name}.csv")
            continue
        header, rows = read_csv(path, name, rep)
        if header is None:
            continue
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
        if valid_utc:
            utc_firstlast[name] = (valid_utc[0], valid_utc[-1])

        if name in RATE_RULES:
            min_hz, max_gap, sev, _ = RATE_RULES[name]
            if st["rows"] < 2:
                rep.add(sev, f"{name}: only {st['rows']} rows")
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
                       f"{best:.1f} ms best-adjacent-anchor")
                if best > UTC_DEV_FAIL_MS:
                    rep.add("FAIL", msg)
                elif best > UTC_DEV_OK_MS:
                    rep.add("WARN", msg)
                else:
                    rep.ok(msg)

        if name == "location":
            check_location(rows, idx, st, rep)
    return span, utc_firstlast


def check_location(rows, idx, st, rep):
    if st["rows"] == 0:
        rep.add("FAIL", "location: 0 rows (no GPS fix)")
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
    started = parse_iso(meta.get("startedAtUtc")) if meta else None
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


def check_labels(folder, rep, span):
    print("\n== labels.csv ==")
    path = os.path.join(folder, "labels.csv")
    if not os.path.exists(path):
        rep.add("WARN", "MISSING labels.csv")
        return
    header, rows = read_csv(path, "labels", rep)
    if header is None:
        return
    idx = {h: i for i, h in enumerate(header)}
    counts = {}
    outside = 0
    for _, r in rows:
        typ = r[idx["type"]] if "type" in idx else "?"
        counts[typ] = counts.get(typ, 0) + 1
        t = fnum(r[idx.get("t_up", 0)])
        if span[0] is not None and t is not None and not (span[0] - 5 <= t <= span[1] + 5):
            outside += 1
    print(f"  rows={len(rows)}  " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    if not rows:
        rep.add("WARN", "labels.csv has no labels")
    else:
        rep.ok(f"{len(rows)} labels")
    if outside:
        rep.add("WARN", f"labels: {outside} labels have t_up outside the motion data time span")


def check_audio(folder, rep, anchors_present):
    print("\n== audio ==")
    files = sorted(f for f in os.listdir(folder)
                   if f.startswith("audio_") and f.endswith(".m4a"))
    legacy = os.path.exists(os.path.join(folder, "audio.m4a"))
    if legacy:
        files.append("audio.m4a")
    total = 0
    for f in files:
        size = os.path.getsize(os.path.join(folder, f))
        total += size
        print(f"  {f:16s} {size:>12,d} bytes")
        if size == 0:
            rep.add("WARN", f"{f} is empty (0 bytes)")
    if not files:
        print("  audio MISSING")
        rep.add("WARN", "MISSING audio (no audio_*.m4a or audio.m4a)")
        return
    print(f"  total {total:,d} bytes in {len(files)} file(s)")

    seg_path = os.path.join(folder, "audio_segments.csv")
    if not os.path.exists(seg_path):
        if not legacy:
            rep.add("WARN", "MISSING audio_segments.csv (cannot cross-check audio files)")
        return
    header, rows = read_csv(seg_path, "audio_segments", rep)
    if header is None:
        return
    idx = {h: i for i, h in enumerate(header)}
    events = {}
    started = []
    for _, r in rows:
        ev = r[idx["event"]]
        events[ev] = events.get(ev, 0) + 1
        if ev == "start":
            started.append(r[idx["file"]])
    print("  audio_segments events: " + ", ".join(f"{k}={v}" for k, v in sorted(events.items())))
    on_disk = set(f for f in files if f != "audio.m4a")
    missing = [f for f in started if f not in on_disk]
    extra = sorted(on_disk - set(started))
    if missing:
        rep.add("FAIL", f"audio files listed as started but missing on disk: {', '.join(missing)}")
    if extra:
        rep.add("WARN", f"audio files on disk without a start event: {', '.join(extra)}")
    if not missing and not extra:
        rep.ok(f"{len(started)} audio segment(s) match audio_segments.csv")

    clock_path = os.path.join(folder, "clock.csv")
    if anchors_present and os.path.exists(clock_path):
        with open(clock_path, newline="", encoding="utf-8", errors="replace") as fh:
            n_audio_start = sum(1 for r in csv.DictReader(fh) if r.get("source") == "audio_start")
        if n_audio_start != len(started):
            rep.add("WARN", f"clock.csv has {n_audio_start} audio_start rows but "
                            f"audio_segments.csv has {len(started)} start events")


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
    pre = meta.get("preflight") or {}
    print(f"  sessionId        : {meta.get('sessionId')}")
    print(f"  startedAtUtc     : {meta.get('startedAtUtc')}")
    print(f"  endedAtUtc       : {meta.get('endedAtUtc')}")
    print(f"  recovered        : {meta.get('recovered')}")
    print(f"  syntheticSensors : {meta.get('syntheticSensors')}")
    print(f"  preflight.overridden: {pre.get('overridden') if pre else '(no preflight)'}")
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
    return meta


def main(argv):
    if len(argv) != 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0 if len(argv) == 2 else 2
    folder = argv[1]
    if not os.path.isdir(folder):
        print(f"not a directory: {folder}")
        return 2
    print(f"Session folder: {os.path.abspath(folder)}")
    rep = Report()
    meta = check_session_json(folder, rep)
    anchors = load_clock(folder, rep)
    span, utc_firstlast = check_streams(folder, rep, anchors)
    check_utc_realtime(utc_firstlast, meta, rep)
    check_labels(folder, rep, span)
    check_audio(folder, rep, bool(anchors))

    overall = rep.overall
    print("\n== summary ==")
    for sev in ("FAIL", "WARN"):
        for s, msg in rep.issues:
            if s == sev:
                print(f"  {sev}: {msg.splitlines()[0]}")
    n_fail = sum(1 for s, _ in rep.issues if s == "FAIL")
    n_warn = sum(1 for s, _ in rep.issues if s == "WARN")
    print(f"OVERALL: {overall}  ({n_fail} fail, {n_warn} warn)")
    return 1 if overall == "FAIL" else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
