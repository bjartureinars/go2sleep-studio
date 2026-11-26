"""Build history.html: self-contained dashboard of all nights in data/history_seconds.csv."""
import csv, json, datetime as dt
STEP = 10
rows = [(dt.datetime.fromisoformat(r["time"]), int(r["hr"]), int(r["spo2"]), int(r["motion"]), int(r["x10"]), int(r["signal_s"]))
        for r in csv.DictReader(open("data/history_seconds.csv"))]
sess, cur = [], [rows[0]]
for a, b in zip(rows, rows[1:]):
    if (b[0] - a[0]).total_seconds() > 600: sess.append(cur); cur = []
    cur.append(b)
sess.append(cur)
nights, skipped = [], []
for s in sess:
    dur = (s[-1][0] - s[0][0]).total_seconds()
    if dur < 3600: skipped.append(f"{s[0][0]:%d %b %H:%M} ({dur/60:.0f} min)"); continue
    t0 = int(s[0][0].timestamp()); n = int(dur // STEP) + 1
    bins = [[] for _ in range(n)]
    for r in s: bins[min(int((r[0].timestamp() - t0) // STEP), n - 1)].append(r)
    def agg(i, f):
        out = []
        for b in bins:
            v = [x[i] for x in b if x[i] > 0] if i in (1, 2) else [x[i] for x in b]
            out.append(None if not v else round(f(v), 1))
        return out
    hr = agg(1, lambda v: sum(v) / len(v)); sp = agg(2, min)
    mo = agg(3, max); x10 = agg(4, lambda v: sum(v) / len(v)); sl = agg(5, lambda v: sum(v) / len(v))
    hv = [x for x in hr if x]; raw_hr = [r[1] for r in s if r[1]]; sv = [r[2] for r in s if r[2]]
    nights.append(dict(label=f"{s[0][0]:%a %d %b %H:%M}", start=t0, step=STEP, hr=hr, spo2=sp, motion=mo, x10=x10, slow=sl,
        stats=dict(hours=round(dur / 3600, 1), hr_avg=round(sum(hv) / len(hv), 1), hr_min=min(raw_hr),
                   spo2_avg=round(sum(sv) / len(sv), 1), spo2_min=min(sv), under90=sum(v < 90 for v in sv),
                   under94=sum(v < 94 for v in sv), samples=len(s), gaps=int(dur) + 1 - len(s))))
import numpy as np, staging as S
_t, _hr, _sp, _mo, _x10 = S.load()
for nt, (a, b) in zip(nights, [x for x in S.split_nights(_t)]):
    F = S.epoch_features(_t[a:b], _hr[a:b], _sp[a:b], _mo[a:b], _x10[a:b], S.SIG_S[a:b]); st, _ = S.stage_night(F)
    lvl = {0: 3, 3: 2, 1: 1, 2: 0}                                   # hypnogram rows: Wake, REM, Light, Deep
    hyp = [lvl.get(int(v)) for v in np.repeat(st, 30 // STEP)]
    L = len(nt["hr"]); hyp = (hyp + [None] * L)[:L]
    nt["stage"] = hyp
    nt["stats"].update(S.summarize(st)); nt["stats"]["odi3"] = round(S.odi3(_sp[a:b]) / ((_t[b - 1] - _t[a]) / 3600), 1)
    nt["stats"]["bad_pct"] = round(100 * float((st == -1).mean()), 1)
tpl = open("history_template.html").read()
open("history.html", "w").write(tpl.replace("/*DATA*/", json.dumps(dict(nights=nights, skipped=skipped), separators=(",", ":"))))
print(len(nights), "nights;", "skipped:", skipped)
