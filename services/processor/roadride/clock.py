"""The phone's two clocks within one trip (plan §9 step 1): motion, labels and the batch windows are on
the uptime clock, GPS fixes carry the wall clock (`CLLocation.timestamp`), and each batch maps one to
the other with an offset the app takes from its latest clock anchor (every ANCHOR_S, spec §4).

When the wall clock steps mid-trip (an NTP correction, a manual change), the fixes switch to the new
clock at once but the batch offsets only at the next anchor, up to ANCHOR_S later, so those fixes were
put up to the step's size away from the motion around them. And the derived UTC times (series,
events) followed the offsets, so a backward step made them run backwards.

- `fix_uptime`: a fix's place on the uptime clock. The upload's CSV has it (`Fix.t_up`, the app's
  step-robust arrival − age); a live batch only has the UTC, so its offset is used, but a fix can't be
  later than the batch it arrived in nor much older, which bounds the error of a large step.
- `place_fixes`: the finalize job knows the offset after the next anchor too, so it decides which fixes
  around a step were taken on which clock: the split that keeps them in order and in their batches.
- `TripClock`: the offset for derived times. Forward steps are followed (the times jump ahead, as the
  phone's did); backward ones are absorbed until a forward step gives them back, so the trip's series
  and events never run backwards.

Stored fixes and labels keep the phone's own times (their rows are deduplicated by them); only derived
times and the computations use the trip's timeline. For a trip without a step, everything is unchanged.
"""

from __future__ import annotations

import dataclasses
import datetime as dt
from dataclasses import dataclass

from .live import BatchFacts, Fix

UTC = dt.timezone.utc

CLOCK_STEP_S = 0.1  # an offset change between batches above this is a step, not ms rounding or slewing
ANCHOR_S = 10.0  # the app's periodic clock anchor (spec §4 clock.csv)
BATCH_S = 2.0  # the app's batch window (spec §6)
FIX_MAX_AGE_S = 15.0  # a fix arrives at most this old (the app keeps cached fixes up to 5 s before start)
FIX_ARRIVAL_TOL_S = 0.5  # timer and delivery slack at the end of a batch window


def _window(f: BatchFacts) -> tuple[float, float]:
    """(t0_up, end_up) of the batch's arrival window on the uptime clock."""
    t0_up = f.t0_utc.timestamp() - f.clock_offset
    newest = (max(f.motion_t) - t0_up) if len(f.motion_t) else 0.0
    return t0_up, t0_up + max(newest, BATCH_S)


def _bounds(f: BatchFacts) -> tuple[float, float]:
    t0_up, end_up = _window(f)
    return t0_up - FIX_MAX_AGE_S, end_up + FIX_ARRIVAL_TOL_S


def fix_uptime(f: BatchFacts, x: Fix) -> float:
    """Where fix `x` of batch `f` goes on the uptime clock."""
    if x.t_up is not None:
        return x.t_up
    lo, hi = _bounds(f)
    return min(max(x.t.timestamp() - f.clock_offset, lo), hi)


def place_fixes(batches: list[BatchFacts]) -> list[list[float]]:
    """`fix_uptime` for every fix of a whole trip (batches in order), with hindsight at each step: the
    step happened after the anchor before batch j-1's offset and by batch j's, so the fixes of that
    stretch are a prefix on the old clock and a suffix on the new one. The split chosen keeps them
    inside their batches' windows, then in time order, then as evenly spaced as possible; with no
    evidence either way it stays at the batch boundary (each batch's own offset)."""
    ups = [[fix_uptime(f, x) for x in f.fixes] for f in batches]
    for j in range(1, len(batches)):
        old, new = batches[j - 1].clock_offset, batches[j].clock_offset
        if abs(new - old) <= CLOCK_STEP_S:
            continue
        since = _window(batches[j - 1])[1] - ANCHOR_S
        idx = [(i, n) for i in range(j + 1)
               if (i == j or abs(batches[i].clock_offset - old) <= CLOCK_STEP_S) and _window(batches[i])[1] > since
               for n, x in enumerate(batches[i].fixes) if x.t_up is None]
        if not idx:
            continue
        taken = set(idx)
        before = [u for i in range(j + 1) for n, u in enumerate(ups[i])
                  if (i, n) not in taken and _window(batches[i])[1] <= since]
        after = [u for i in range(j + 1, len(batches)) for u in ups[i]]
        prev, nxt = (before[-1] if before else None), (after[0] if after else None)
        raw = [batches[i].fixes[n].t.timestamp() for i, n in idx]
        bounds = [_bounds(batches[i]) for i, _ in idx]
        default = sum(1 for i, _ in idx if i < j)
        best = None
        for p in range(len(idx) + 1):
            z = [u - (old if k < p else new) for k, u in enumerate(raw)]
            outside = sum(max(lo - v, 0.0, v - hi) for v, (lo, hi) in zip(z, bounds))
            seq = ([prev] if prev is not None else []) + z + ([nxt] if nxt is not None else [])
            gaps = [b - a for a, b in zip(seq, seq[1:])]
            backwards = sum(max(0.0, -g) for g in gaps)
            mid = sorted(gaps)[len(gaps) // 2] if gaps else 0.0
            uneven = sum((g - mid) ** 2 for g in gaps)
            key = (round(outside, 6), round(backwards, 6), round(uneven, 6), abs(p - default))
            if best is None or key < best[0]:
                best = (key, z)
        for (i, n), v, (lo, hi) in zip(idx, best[1], bounds):
            ups[i][n] = min(max(v, lo), hi)
    return ups


@dataclass
class TripClock:
    """The offset (UTC − uptime) for a trip's derived times, batch by batch in order."""
    prev: float | None = None  # the last batch's own offset
    shift: float = 0.0  # added to it: backward steps not given back yet

    @classmethod
    def from_state(cls, s: dict | None) -> TripClock:
        s = s or {}
        return cls(prev=s.get("prev"), shift=float(s.get("shift", 0.0)))

    def to_state(self) -> dict:
        return {"prev": self.prev, "shift": self.shift}

    def offset(self, raw: float) -> float:
        if self.prev is not None:
            step = raw - self.prev
            if step < -CLOCK_STEP_S:
                self.shift -= step
            elif step > CLOCK_STEP_S:
                self.shift = max(0.0, self.shift - step)
        self.prev = raw
        return raw + self.shift


def normalize(batches: list[BatchFacts], clock: TripClock | None = None) -> list[BatchFacts]:
    """The trip's batches on its own timeline: each batch's offset from `clock`, every fix placed by
    `place_fixes` (kept in `Fix.t_up`) and timed on that offset, labels and the window moved with it.
    The finalize job computes on these and stores the phone's own rows."""
    clock = clock or TripClock()
    ups = place_fixes(batches)
    out = []
    for f, fix_ups in zip(batches, ups):
        model = clock.offset(f.clock_offset)
        shift = dt.timedelta(seconds=model - f.clock_offset)
        fixes = [dataclasses.replace(x, t_up=u, t=x.t if (not shift and u == x.t.timestamp() - f.clock_offset)
                                     else dt.datetime.fromtimestamp(u + model, UTC))
                 for x, u in zip(f.fixes, fix_ups)]
        labels = [dataclasses.replace(lab, t=lab.t + shift) for lab in f.labels] if shift else f.labels
        out.append(dataclasses.replace(f, clock_offset=model, fixes=fixes, labels=labels,
                                       t0_utc=f.t0_utc + shift, end_utc=f.end_utc + shift))
    return out
