"""Decode a capture.py log of 0x3c SECOND_DATA frames into data/history_seconds.csv + nightly summary.
Frame (20 bytes): 5b 3c | yy mm dd hh mi ss | hr spo2 | b8 b9 | b10 | b11 b12 | cnt(u16 b13-14) | b15 | acc(u16 b16-17) |  (offsets into frame after 5b 3c)
motion=x8 (bursty; HR rises after bursts), x10=unknown activity-like, slow_raw=u16 that includes +(record_index & 255); signal_s=slow_raw-(record_index&255) (smooth, moves with body motion; optical/coupling-baseline-like), record_index=flash index. Bytes 9/11/15 are always 0 and dropped."""
import sys, csv, datetime, statistics as st, collections
src = sys.argv[1] if len(sys.argv) > 1 else "data/dump.log"
rows = {}
for l in open(src):
    if l[0] == "#": continue
    b = bytes.fromhex(l.split()[1])
    if b[1] != 0x3c or len(b) != 20: continue
    r = b[2:]
    try: t = datetime.datetime(2000 + r[0], r[1], r[2], r[3], r[4], r[5])
    except ValueError: continue
    rows[t] = (r[6], r[7], r[8], r[10], (r[12] << 16) | (r[13] << 8) | r[14], (r[16] << 8) | r[17])
ts = sorted(rows)
with open("data/history_seconds.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["time", "hr", "spo2", "motion", "x10", "record_index", "slow_raw", "signal_s"])
    for t in ts: w.writerow([t.isoformat(" "), *rows[t], rows[t][5] - (rows[t][4] & 255)])   # signal_s = slow_raw - (record_index & 255): the field contains the index low byte as an additive ramp
print(len(ts), "unique seconds ->", "data/history_seconds.csv")
# split into sessions at gaps > 10 min
sess, cur = [], [ts[0]]
for a, b in zip(ts, ts[1:]):
    if (b - a).total_seconds() > 600: sess.append(cur); cur = []
    cur.append(b)
sess.append(cur)
print(f"{'start':19} {'end':19} {'dur':>6} {'HR avg':>6} {'HR min':>6} {'SpO2 avg':>8} {'SpO2 min':>8} {'<90%':>6} zeros")
for s in sess:
    hr = [rows[t][0] for t in s if rows[t][0]]; sp = [rows[t][1] for t in s if rows[t][1]]
    dur = (s[-1] - s[0]).total_seconds() / 3600
    if not hr: continue
    print(f"{s[0]:%Y-%m-%d %H:%M:%S} {s[-1]:%Y-%m-%d %H:%M:%S} {dur:5.1f}h {st.mean(hr):6.1f} {min(hr):6d} {st.mean(sp):8.1f} {min(sp):8d} {sum(v<90 for v in sp):5d}s {len(s)-len(hr)}")
