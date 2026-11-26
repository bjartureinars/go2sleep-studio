"""Experimental sleep staging from Go2Sleep per-second history (HR + motion + SpO2).

NOT VALIDATED: there is no polysomnography / labeled ground truth for this ring. The model is a
transparent heuristic built from published physiology (see sanity checks in sanity_check()).

Pipeline (30 s epochs, per night):
  1. features: motion-seconds, HR median, HR sd, validity
  2. wake  : Cole-Kripke-style weighted activity over epochs t-4..t+2 (motion byte -> fraction of seconds moving)
  3. stage : within sleep, HR level + 5-min HR variability, z-scored against that night, mapped to Light/Deep/REM
             by Gaussian emission scores + time-of-night priors; Viterbi smoothing with allowed transitions
  4. extras: sleep onset latency, WASO, efficiency, stage %, ODI-3 from SpO2
Stages: 0 Wake, 1 Light, 2 Deep, 3 REM, -1 Unscored (bad signal)
"""
import csv, datetime as dt, numpy as np

EPOCH = 30
SIG_S = None                  # cleaned S signal, filled by load()
USE_EXTRA = True              # use x10 + S roughness (consistently lower in deep sleep on 8/9 nights)
CK_W = np.array([106, 54, 58, 76, 230, 74, 67], float)      # Cole-Kripke weights for t-4..t+2
CK_OFF = 4
WAKE_THRESH = 0.20           # weighted fraction of seconds-with-motion; HR only rises above this level (see calibration note)
MIN_WAKE_EPOCHS = 3          # wake episodes shorter than 90 s are brief arousals, scored as sleep
HR_OK = (35, 130)
STAGES = ["Wake", "Light", "Deep", "REM"]


def load():
    rows = list(csv.DictReader(open("data/history_seconds.csv")))
    t = np.array([dt.datetime.fromisoformat(r["time"]).timestamp() for r in rows])
    f = lambda k: np.array([int(r[k]) for r in rows])
    global SIG_S; SIG_S = f("signal_s").astype(float)
    return t, f("hr"), f("spo2"), f("motion"), f("x10")


def split_nights(t, min_hours=1.0, gap=600):
    cuts = np.where(np.diff(t) > gap)[0] + 1
    out = []
    for a, b in zip(np.r_[0, cuts], np.r_[cuts, len(t)]):
        if t[b - 1] - t[a] >= min_hours * 3600:
            out.append((a, b))
    return out


def epoch_features(t, hr, spo2, mo, x10, S=None):
    t0 = t[0]; idx = ((t - t0) // EPOCH).astype(int); n = idx[-1] + 1
    F = dict(n=n, t0=t0)
    valid_hr = (hr >= HR_OK[0]) & (hr <= HR_OK[1])
    F["act"] = np.bincount(idx, weights=(mo > 0), minlength=n)                    # seconds with motion 0..30
    F["nvalid"] = np.bincount(idx, weights=valid_hr, minlength=n)
    hr_med = np.full(n, np.nan); hr_sd = np.full(n, np.nan)
    for e in range(n):
        v = hr[idx == e][valid_hr[idx == e]]
        if len(v) >= 20: hr_med[e] = np.median(v); hr_sd[e] = v.std()
    F["hr"], F["hr_sd"] = hr_med, hr_sd
    s = np.full(n, np.nan)
    for e in range(n):
        v = spo2[idx == e]; v = v[v > 0]
        if len(v): s[e] = v.min()
    F["spo2"] = s
    F["x10"] = np.array([x10[idx == e].mean() if (idx == e).any() else np.nan for e in range(n)])
    F["srough"] = np.full(n, np.nan)
    if S is not None:
        for e in range(n):
            v = S[idx == e]
            if len(v) > 2: F["srough"][e] = np.abs(np.diff(v)).mean()
    return F


def interp(x):
    x = x.copy(); ok = ~np.isnan(x)
    if ok.sum() < 2: return np.nan_to_num(x)
    x[~ok] = np.interp(np.flatnonzero(~ok), np.flatnonzero(ok), x[ok]); return x


def wake_score(act):
    a = act / EPOCH; pad = np.pad(a, (CK_OFF, len(CK_W) - CK_OFF - 1))
    return np.array([(pad[i:i + len(CK_W)] * CK_W).sum() / CK_W.sum() for i in range(len(a))])


def rolling(x, w, fn):
    h = w // 2; return np.array([fn(x[max(0, i - h): i + h + 1]) for i in range(len(x))])


def viterbi(logE, logT, logPrior):
    n, k = logE.shape; dp = np.full((n, k), -1e18); bp = np.zeros((n, k), int)
    dp[0] = logPrior + logE[0]
    for i in range(1, n):
        c = dp[i - 1][:, None] + logT; bp[i] = c.argmax(0); dp[i] = c.max(0) + logE[i]
    path = np.zeros(n, int); path[-1] = dp[-1].argmax()
    for i in range(n - 1, 0, -1): path[i - 1] = bp[i, path[i]]
    return path


def stage_night(F):
    n = F["n"]; bad = np.isnan(F["hr"])
    hr = interp(F["hr"]); W = wake_score(F["act"])
    wake = W > WAKE_THRESH
    i = 0
    while i < n:                                                       # drop wake runs shorter than MIN_WAKE_EPOCHS
        if wake[i]:
            j = i
            while j < n and wake[j]: j += 1
            if j - i < MIN_WAKE_EPOCHS: wake[i:j] = False
            i = j
        else: i += 1
    # sleep onset: first run of >=10 min (20 epochs) of non-wake; trailing wake after last such run stays wake
    sleeplike = ~wake
    stage = np.zeros(n, int)
    # ---- HR features
    hr_s = rolling(hr, 5, np.median)                                  # ~2.5 min median
    ok = ~wake & ~bad                                                 # remove slow circadian HR decline (quadratic fit), keep ~90 min cycles
    if ok.sum() > 60:
        x = np.arange(n) / n; co = np.polyfit(x[ok], hr_s[ok], 2); hr_s = hr_s - np.polyval(co, x) + np.median(hr_s[ok])
    hr_v = rolling(hr, 11, np.std)                                    # ~5.5 min variability of epoch HR
    ref = ~wake & ~bad
    def z(x):
        m = np.median(x[ref]); s = 1.4826 * np.median(np.abs(x[ref] - m)) + 1e-6; return (x - m) / s
    zh, zv = z(hr_s), z(hr_v)
    act = F["act"] / EPOCH
    # ---- emissions for Light, Deep, REM  (mean z-score of HR level, HR variability, motion)
    mu = {1: (0.0, 0.0, 0.03), 2: (-1.1, -0.9, 0.0), 3: (0.6, 1.0, 0.0)}
    sd = {1: (1.0, 1.0, 0.06), 2: (0.8, 0.8, 0.03), 3: (0.9, 1.0, 0.03)}
    extra = []
    if USE_EXTRA and not np.isnan(F["srough"]).all():
        for key in ("x10", "srough"):
            v = rolling(interp(F[key]), 5, np.mean); m_ = np.median(v[ref]); sd_ = 1.4826 * np.median(np.abs(v[ref] - m_)) + 1e-6
            extra.append((v - m_) / sd_)
        emu = {1: 0.05, 2: -0.5, 3: 0.1}                                  # means from the cross-night per-stage analysis (small, shared sd 1.0)
    tn = np.arange(n) * EPOCH / 3600.0                                # hours since start
    logE = np.zeros((n, 3))
    for j, s in enumerate((1, 2, 3)):
        for f, x in enumerate((zh, zv, act)):
            logE[:, j] += -0.5 * ((x - mu[s][f]) / sd[s][f]) ** 2 - np.log(sd[s][f])
    for j, s_ in enumerate((1, 2, 3)):
        for x in extra: logE[:, j] += -0.5 * (x - emu[s_]) ** 2
    # time-of-night priors (deep decays, REM grows) -- standard architecture of adult sleep
    logE[:, 1] += 0.0
    logE[:, 2] += np.log(np.clip(np.exp(-tn / 2.8), 0.15, 1.0))
    logE[:, 0 + 2] += np.log(np.clip(0.35 + tn / 7.0, 0.35, 1.0))
    # transitions (rows=from, cols=to) over Light, Deep, REM; deep->REM and REM->deep discouraged
    P = np.array([[0.960, 0.020, 0.020], [0.030, 0.968, 0.002], [0.030, 0.002, 0.968]])
    seq = viterbi(logE, np.log(P), np.log([0.8, 0.1, 0.1]))
    stage = seq + 1
    stage[wake] = 0
    # ignore isolated wake blips (<2 epochs) inside sleep -> light; require >=10 min before first sleep for onset
    stage[bad] = -1
    return stage, W


def odi3(spo2_1hz):
    v = np.where(spo2_1hz > 0, spo2_1hz, np.nan); n = len(v); ev = 0; i = 0
    while i < n:
        base = np.nanmax(v[max(0, i - 120): i + 1]) if i else v[0]
        if not np.isnan(v[i]) and not np.isnan(base) and v[i] <= base - 3:
            j = i
            while j < n and not np.isnan(v[j]) and v[j] <= base - 2: j += 1
            if j - i >= 10: ev += 1
            i = j + 30
        else: i += 1
    return ev


def summarize(stage, sleep_hours_denominator=True):
    inbed = (stage >= 0).sum() * EPOCH / 60.0
    asleep = np.isin(stage, (1, 2, 3))
    if not asleep.any(): return {}
    first = np.argmax(asleep)
    # first persistent sleep (>=10 min with <=2 wake epochs)
    for i in range(len(stage) - 20):
        if (stage[i:i + 20] > 0).sum() >= 18: first = i; break
    last = len(stage) - 1 - np.argmax(asleep[::-1])
    tst = asleep[first:last + 1].sum() * EPOCH / 60.0
    waso = ((stage[first:last + 1] == 0).sum()) * EPOCH / 60.0
    d = dict(inbed_min=round(inbed), onset_min=round(first * EPOCH / 60.0), tst_min=round(tst), waso_min=round(waso),
             eff=round(100 * tst / inbed, 1) if inbed else 0)
    for k, nm in ((1, "light"), (2, "deep"), (3, "rem")):
        d[nm + "_pct"] = round(100 * (stage[first:last + 1] == k).sum() / max(1, (stage[first:last + 1] >= 0).sum()), 1)
    return d


def sanity_check(stage):
    """Physiology checks (literature norms for healthy adults): deep concentrated early, REM later, ~90 min cycles."""
    asl = np.isin(stage, (1, 2, 3)); idx = np.flatnonzero(asl)
    if len(idx) < 120: return {}
    half = idx[len(idx) // 2]
    deep = stage == 2; rem = stage == 3
    deep_first = deep[:half].sum() / max(1, deep.sum())
    rem_second = rem[half:].sum() / max(1, rem.sum())
    # cycle period from REM indicator autocorrelation
    x = rem[idx[0]:idx[-1]].astype(float); x -= x.mean(); ac = np.correlate(x, x, "full")[len(x) - 1:]; ac /= ac[0] + 1e-9
    lo, hi = 120, 240    # 60..120 min
    per = (lo + np.argmax(ac[lo:hi])) * EPOCH / 60.0 if len(ac) > hi else np.nan
    # bout counts
    ch = np.sum(np.diff(stage[idx[0]:idx[-1] + 1]) != 0)
    return dict(deep_in_first_half=round(100 * deep_first), rem_in_second_half=round(100 * rem_second),
                cycle_min=None if np.isnan(per) else round(per), transitions_per_hour=round(ch / ((idx[-1] - idx[0]) * EPOCH / 3600), 1))


if __name__ == "__main__":
    t, hr, spo2, mo, x10 = load(); res = []
    print(f"{'night':17} {'inbed':>5} {'TST':>4} {'onset':>5} {'WASO':>4} {'eff%':>5} {'light':>5} {'deep':>5} {'REM':>5} | {'deep1st%':>8} {'rem2nd%':>7} {'cyc':>4} {'trans/h':>7} {'ODI3':>5} {'bad%':>4}")
    for a, b in split_nights(t):
        F = epoch_features(t[a:b], hr[a:b], spo2[a:b], mo[a:b], x10[a:b], SIG_S[a:b]); st, W = stage_night(F)
        s = summarize(st); c = sanity_check(st); o = odi3(spo2[a:b]); bad = 100 * (st == -1).mean()
        print(f"{dt.datetime.fromtimestamp(t[a]):%a %d %b %H:%M} {s['inbed_min']:5d} {s['tst_min']:4d} {s['onset_min']:5d} {s['waso_min']:4d} {s['eff']:5.1f} {s['light_pct']:5.1f} {s['deep_pct']:5.1f} {s['rem_pct']:5.1f} | {c.get('deep_in_first_half',0):8d} {c.get('rem_in_second_half',0):7d} {str(c.get('cycle_min')):>4} {c.get('transitions_per_hour',0):7.1f} {o/((t[b-1]-t[a])/3600):5.1f} {bad:4.1f}")
