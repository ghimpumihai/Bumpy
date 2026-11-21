"""Signal processing for one trip (plan §9 steps 2, 4, 5, 6): vertical acceleration, road roughness,
potholes and the ISO 2631-1 motion-sickness dose.

One pure pipeline, fed in pieces. The stream processor feeds it one 2-second batch at a time and saves
`to_state()` in the database with the rows it wrote; the finalize job can feed a whole trip at once.
Both must give the same numbers, so every piece of memory (filter states, the resampling grid, partial
windows, the dose, the forward-axis estimate, an open pothole) lives in the JSON-serializable state,
and tests feed the same signal whole and in random chunks.

Inputs are the app's deviceMotion samples: user acceleration and gravity in g, in the phone's frame,
at a nominal 100 Hz with jitter. They are resampled onto a uniform 100 Hz grid (IIR filters assume a
fixed rate); a time gap or a missing batch resets the filters and starts a new grid.

ISO 2631-1 Wf (motion sickness): H = Hh·Hl·Ht·Hs with f1=0.08, f2=0.63, f3=∞, f4=0.25, Q4=0.86,
f5=0.0625, Q5=0.80, f6=0.1, Q6=0.80 Hz (parameters and transfer functions as reproduced in the Chalmers
thesis odr.chalmers.se/bitstreams/7acd3e0a-09bd-4914-a01e-cfe3832b3ab3; MSDV = (∫a_w² dt)^½ as in
arXiv:2501.17664 eq. 3). Its poles sit far below 100 Hz, so the signal is low-passed and decimated to
20 Hz before Wf is applied.

Thresholds for potholes and the forward-axis estimate are PROVISIONAL: they haven't seen a real drive.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np
from scipy import signal

G = 9.80665  # m/s² per g

FS = 100.0  # resampling grid, Hz
DT = 1.0 / FS
DECIMATE = 5  # → 20 Hz for Wf: low enough for well-conditioned poles at 0.06 Hz, high enough that
#                 the bilinear transform's frequency warping stays < 1 % up to 0.63 Hz (10 Hz gave 4 %)
FS_WF = FS / DECIMATE
SERIES_EVERY = 20  # → 5 Hz session_series
MAX_GAP_S = 0.25  # a hole longer than this in the motion samples resets the filters

ROUGH_BAND_HZ = (1.0, 30.0)  # plan §9 step 4
ROUGHNESS_TAU_S = 5.0  # roughnessNow: RMS over roughly the last 5 s (exponential average)

POTHOLE_THRESHOLD_MS2 = 5.0  # PROVISIONAL: |band-passed vertical| above this starts a pothole
POTHOLE_MIN_SPEED_MS = 15 / 3.6  # plan §9 step 5: only above 15 km/h
POTHOLE_PEAK_WINDOW_S = 0.3  # the event's peak is searched this long after the crossing
POTHOLE_REFRACTORY_S = 1.0  # one pothole per second at most

FIX_MAX_HOLD_S = 3.0  # use the last GPS speed for at most this long
FWD_MIN_DVDT = 0.5  # m/s², only clear speed changes say where "forward" is
FWD_MIN_DT, FWD_MAX_DT = 0.5, 3.0  # s between the two fixes of a speed change
FWD_MIN_EVIDENCE = 10  # speed changes before the forward axis is trusted

WF = dict(f1=0.08, f2=0.63, f4=0.25, q4=0.86, f5=0.0625, q5=0.80, f6=0.1, q6=0.80)


# --- Filters ------------------------------------------------------------------------------

def _w(f: float) -> float:
    return 2 * math.pi * f


def wf_analog_factors() -> list[tuple[list[float], list[float]]]:
    """Wf as four analog (b, a) factors in s (f3 = ∞, so Ht has no zero)."""
    w1, w2, w4, w5, w6 = (_w(WF[k]) for k in ("f1", "f2", "f4", "f5", "f6"))
    hh = ([1.0, 0.0, 0.0], [1.0, math.sqrt(2) * w1, w1 ** 2])  # high-pass, band limiting
    hl = ([w2 ** 2], [1.0, math.sqrt(2) * w2, w2 ** 2])  # low-pass, band limiting
    ht = ([w4 ** 2], [1.0, w4 / WF["q4"], w4 ** 2])  # acceleration-velocity transition
    # Upward step: (1 + p/(Q5ω5) + (p/ω5)²)/(1 + p/(Q6ω6) + (p/ω6)²) · (ω5/ω6)² = N5(s)/N6(s)
    hs = ([1.0, w5 / WF["q5"], w5 ** 2], [1.0, w6 / WF["q6"], w6 ** 2])
    return [hh, hl, ht, hs]


def wf_analog_gain(freqs_hz: np.ndarray) -> np.ndarray:
    w = 2 * np.pi * np.asarray(freqs_hz, dtype=float)
    gain = np.ones_like(w)
    for b, a in wf_analog_factors():
        gain *= np.abs(signal.freqs(b, a, worN=w)[1])
    return gain


def _wf_sos(fs: float) -> np.ndarray:
    zs, ps, k = [], [], 1.0
    for b, a in wf_analog_factors():
        z, p, kk = signal.tf2zpk(b, a)
        zd, pd, kd = signal.bilinear_zpk(z, p, kk, fs)
        zs.extend(zd)
        ps.extend(pd)
        k *= kd
    return signal.zpk2sos(np.array(zs), np.array(ps), k)


SOS_BAND = signal.butter(4, ROUGH_BAND_HZ, btype="bandpass", fs=FS, output="sos")
SOS_LOW = signal.butter(4, 2.0, btype="lowpass", fs=FS, output="sos")  # anti-alias before 10 Hz
SOS_WF = _wf_sos(FS_WF)


def wf_digital_gain(freqs_hz: np.ndarray) -> np.ndarray:
    return np.abs(signal.sosfreqz(SOS_WF, worN=np.asarray(freqs_hz, dtype=float), fs=FS_WF)[1])


# --- Results ------------------------------------------------------------------------------

@dataclass
class SeriesPoint:
    t: float  # epoch seconds
    a_vert: float  # m/s², band-passed vertical, the largest |value| of the 0.2 s window (signed)
    a_lat: float  # m/s², low-passed; 0 until the forward axis is known
    a_lon: float
    speed: float | None  # m/s
    msdv: float  # m/s^1.5 so far
    # For the finalize job's segment passes (not stored in session_series):
    rough_rms: float = 0.0  # m/s², RMS of the band-passed vertical over the 0.2 s window
    dose_inc: float = 0.0  # ∫ a_w² dt over the window (m²/s³), so a pass's a_w RMS = √(Σ dose_inc / Σ dt)


@dataclass
class Event:
    t: float
    type: str
    magnitude: float  # m/s²
    speed: float | None
    confidence: float


@dataclass
class FeedResult:
    series: list[SeriesPoint] = field(default_factory=list)
    events: list[Event] = field(default_factory=list)
    roughness_now: float | None = None
    msdv: float = 0.0
    reset: bool = False  # filters restarted (gap) during this feed


# --- Pipeline -----------------------------------------------------------------------------

def _zeros(sos: np.ndarray, channels: int = 1) -> list:
    return np.zeros((channels, sos.shape[0], 2)).tolist()


class Pipeline:
    def __init__(self, state: dict | None = None):
        s = state or {}
        self.dose = float(s.get("dose", 0.0))  # ∫ a_w² dt over the whole trip, never reset
        self.forward_sum = list(s.get("forward_sum", [0.0, 0.0, 0.0]))
        self.forward_n = int(s.get("forward_n", 0))
        self.prev_fix = s.get("prev_fix")  # [t, speed or None]
        self.h_acc = list(s.get("h_acc", [0.0, 0.0, 0.0]))
        self.h_n = int(s.get("h_n", 0))
        self.last_event_t = s.get("last_event_t")
        self.open_event = s.get("open_event")  # [t, peak, speed] while searching the peak
        self.rough_ema = s.get("rough_ema")
        self.grid = s.get("grid")  # None until the first sample, then the segment's resampling state
        # Fixes newer than the last processed sample wait here, so they're taken at their own time
        # whatever the batch boundaries are.
        self.pending_fixes = [tuple(f) for f in s.get("pending_fixes", [])]

    def to_state(self) -> dict:
        return {
            "dose": self.dose, "forward_sum": self.forward_sum, "forward_n": self.forward_n,
            "prev_fix": self.prev_fix, "h_acc": self.h_acc, "h_n": self.h_n,
            "last_event_t": self.last_event_t, "open_event": self.open_event,
            "rough_ema": self.rough_ema, "grid": self.grid,
            "pending_fixes": [list(f) for f in self.pending_fixes],
        }

    # -- helpers --

    @property
    def forward_known(self) -> bool:
        return self.forward_n >= FWD_MIN_EVIDENCE and np.linalg.norm(self.forward_sum) > 0

    def _new_grid(self, t: float, sample: list[float]) -> dict:
        ua_g = np.array(sample[:6])
        x0 = self._vert(ua_g[None, :])[0]
        return {
            "origin": t, "k": 0, "prev": [t] + list(sample),
            "zi_band": _zeros(SOS_BAND)[0],
            "zi_low": (signal.sosfilt_zi(SOS_LOW) * x0).tolist(),
            "zi_h": _zeros(SOS_LOW, 3),
            "zi_wf": _zeros(SOS_WF)[0],
            "win": {"n": 0, "peak": 0.0, "lat": 0.0, "lon": 0.0, "b2": 0.0, "aw2": 0.0},
        }

    @staticmethod
    def _down(g: np.ndarray) -> np.ndarray:
        n = np.linalg.norm(g, axis=1, keepdims=True)
        n[n == 0] = 1.0
        return g / n

    def _vert(self, ua_g: np.ndarray) -> np.ndarray:
        """Upward acceleration, m/s²: user acceleration projected on minus the gravity direction."""
        down = self._down(ua_g[:, 3:6])
        return -np.einsum("ij,ij->i", ua_g[:, 0:3], down) * G

    def _speed_at(self, t: float) -> float | None:
        """Causal: the last fix at or before t (fixes are taken in time order before each sample).
        Never looks ahead, so a batch that doesn't contain the next fix yet gives the same answer."""
        before = self.prev_fix
        if before is None or before[1] is None or before[0] > t:
            return None
        return before[1] if t - before[0] <= FIX_MAX_HOLD_S else None

    def _take_fix(self, t: float, speed: float | None) -> None:
        if self.prev_fix and self.prev_fix[1] is not None and speed is not None and self.h_n > 0:
            dt_fix = t - self.prev_fix[0]
            if FWD_MIN_DT <= dt_fix <= FWD_MAX_DT:
                dvdt = (speed - self.prev_fix[1]) / dt_fix
                if abs(dvdt) >= FWD_MIN_DVDT:
                    mean_h = np.array(self.h_acc) / self.h_n
                    self.forward_sum = (np.array(self.forward_sum) + dvdt * mean_h).tolist()
                    self.forward_n += 1
        self.h_acc, self.h_n = [0.0, 0.0, 0.0], 0
        self.prev_fix = [t, speed]

    # -- main entry --

    def feed(self, t: np.ndarray, ua: np.ndarray, grav: np.ndarray,
             fixes: list[tuple[float, float | None]], *, reset: bool = False) -> FeedResult:
        """t: epoch seconds (n,), ua and grav: (n, 3) in g, phone frame. fixes: (epoch s, speed m/s)."""
        out = FeedResult()
        fixes = sorted(set(self.pending_fixes) | {(float(ft), fv) for ft, fv in fixes},
                       key=lambda f: f[0])
        self.pending_fixes = []
        order = np.argsort(t, kind="stable")
        t = np.asarray(t, dtype=float)[order]
        samples = np.hstack([np.asarray(ua, float), np.asarray(grav, float)])[order]
        if reset:
            self.grid = None
            out.reset = True
        if len(t) and self.grid is not None and abs(t[0] - self.grid["prev"][0]) > MAX_GAP_S:
            # A hole, or the clock jumped backwards: either way the filters can't continue.
            self.grid = None
            out.reset = True
        if len(t) == 0:
            self.pending_fixes = fixes  # no samples to place them against yet
            out.msdv = math.sqrt(self.dose)
            out.roughness_now = self._rough()
            return out
        if self.grid is None:
            self.grid = self._new_grid(float(t[0]), samples[0].tolist())

        gr = self.grid
        # Resample onto the uniform grid, interpolating from the last sample of the previous feed.
        src_t = np.concatenate([[gr["prev"][0]], t])
        src = np.vstack([np.array(gr["prev"][1:])[None, :], samples])
        # np.interp needs strictly increasing x and doesn't check it. Keep only samples later than
        # everything before them (an overlap with the previous batch is dropped, not interleaved).
        running_max = np.maximum.accumulate(src_t)
        keep = np.concatenate([[True], src_t[1:] > running_max[:-1]])
        src_t, src = src_t[keep], src[keep]
        k0 = gr["k"]
        k1 = int(math.floor((src_t[-1] - gr["origin"]) / DT + 1e-9))
        if k1 >= k0:
            ks = np.arange(k0, k1 + 1)
            gt = gr["origin"] + ks * DT
            grid = np.column_stack([np.interp(gt, src_t, src[:, c]) for c in range(6)])
            self._process(ks, gt, grid, fixes, out)
            gr["k"] = int(k1 + 1)
        else:
            self.pending_fixes = fixes
        gr["prev"] = [float(src_t[-1])] + src[-1].tolist()
        out.msdv = math.sqrt(self.dose)
        out.roughness_now = self._rough()
        return out

    def _rough(self) -> float | None:
        return None if self.rough_ema is None else math.sqrt(self.rough_ema)

    def _process(self, ks: np.ndarray, gt: np.ndarray, grid: np.ndarray,
                 fixes: list[tuple[float, float | None]], out: FeedResult) -> None:
        gr = self.grid
        down = self._down(grid[:, 3:6])
        ua = grid[:, 0:3]
        vert = -np.einsum("ij,ij->i", ua, down) * G
        horiz = (ua + np.einsum("ij,ij->i", ua, down)[:, None] * down * -1.0) * G  # ua minus its vertical part

        band, zb = signal.sosfilt(SOS_BAND, vert, zi=np.array(gr["zi_band"]))
        low, zl = signal.sosfilt(SOS_LOW, vert, zi=np.array(gr["zi_low"]))
        zh = np.array(gr["zi_h"])
        h_low = np.empty_like(horiz)
        for c in range(3):
            h_low[:, c], zh[c] = signal.sosfilt(SOS_LOW, horiz[:, c], zi=zh[c])
        gr["zi_band"], gr["zi_low"], gr["zi_h"] = zb.tolist(), zl.tolist(), zh.tolist()

        # Motion-sickness dose: Wf on the 20 Hz decimation of the low-passed vertical.
        dec = ks % DECIMATE == 0
        if dec.any():
            aw, zw = signal.sosfilt(SOS_WF, low[dec], zi=np.array(gr["zi_wf"]))
            gr["zi_wf"] = zw.tolist()
        else:
            aw = np.empty(0)
        aw_iter = iter(aw)

        alpha = DT / ROUGHNESS_TAU_S
        fix_i = 0
        win = gr["win"]
        for i in range(len(ks)):
            tt = float(gt[i])
            while fix_i < len(fixes) and fixes[fix_i][0] <= tt:
                self._take_fix(*fixes[fix_i])
                fix_i += 1
            b = float(band[i])
            self.rough_ema = b * b if self.rough_ema is None else self.rough_ema + alpha * (b * b - self.rough_ema)
            win["b2"] = win.get("b2", 0.0) + b * b
            if dec[i]:
                a = float(next(aw_iter))
                self.dose += a * a / FS_WF
                win["aw2"] = win.get("aw2", 0.0) + a * a / FS_WF
            self.h_acc = (np.array(self.h_acc) + h_low[i]).tolist() if self.h_n else h_low[i].tolist()
            self.h_n += 1

            self._pothole(tt, b, out)

            # 5 Hz series window
            if abs(b) > abs(win["peak"]) or win["n"] == 0:
                win["peak"] = b
            if self.forward_known:
                fwd, lat = self._axes(down[i])
                win["lon"] += float(h_low[i] @ fwd)
                win["lat"] += float(h_low[i] @ lat)
            win["n"] += 1
            if (int(ks[i]) + 1) % SERIES_EVERY == 0:
                out.series.append(SeriesPoint(
                    t=tt, a_vert=round(win["peak"], 4), a_lat=round(win["lat"] / win["n"], 4),
                    a_lon=round(win["lon"] / win["n"], 4), speed=self._speed_at(tt),
                    msdv=round(math.sqrt(self.dose), 5),
                    rough_rms=math.sqrt(win.get("b2", 0.0) / win["n"]), dose_inc=win.get("aw2", 0.0)))
                win.update(n=0, peak=0.0, lat=0.0, lon=0.0, b2=0.0, aw2=0.0)
        self.pending_fixes = list(fixes[fix_i:])  # later than the last sample: taken next time

    def _axes(self, down: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        f = np.array(self.forward_sum)
        f = f - (f @ down) * down  # keep it horizontal for the current attitude
        n = np.linalg.norm(f)
        f = f / n if n > 0 else f
        left = np.cross(-down, f)  # up × forward = left; aLat is positive to the left
        return f, left

    def _pothole(self, t: float, b: float, out: FeedResult) -> None:
        if self.open_event is not None:
            et, peak, spd = self.open_event
            if t - et <= POTHOLE_PEAK_WINDOW_S:
                if abs(b) > peak:
                    self.open_event = [et, abs(b), spd]
                return
            out.events.append(Event(t=et, type="pothole", magnitude=round(peak, 3), speed=spd,
                                    confidence=round(min(1.0, peak / (2 * POTHOLE_THRESHOLD_MS2)), 3)))
            self.open_event = None
        if abs(b) < POTHOLE_THRESHOLD_MS2:
            return
        if self.last_event_t is not None and t - self.last_event_t < POTHOLE_REFRACTORY_S:
            return
        speed = self._speed_at(t)
        if speed is None or speed < POTHOLE_MIN_SPEED_MS:
            return
        self.open_event = [t, abs(b), speed]
        self.last_event_t = t
