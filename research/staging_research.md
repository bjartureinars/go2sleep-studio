# Sleep staging, oximetry and sleep score for the Go2Sleep ring: research and algorithm spec

Scope: on-device staging (Wake / Light (N1+N2) / Deep (N3) / REM) and scoring from the ring's decoded per-second history:
`hr` (1 Hz, firmware-smoothed bpm, no RR intervals), `spo2` (%), `motion` (0, bursts 5-130), `x10` (0-57 roughness/activity),
`signal_s` (optical coupling baseline). 30 s epochs, 7-9 h nights, **no labelled ground truth for this ring**.

Everything below is either (a) taken from a cited source, or (b) marked **[design choice]** when it is my engineering
judgement to make the spec implementable. Numbers marked [design choice] are starting points to tune against the
sanity priors in section 4.6, not validated values.

---

## 0. Diagnosis of the current `staging.py` (why REM is ~5%)

Read of `/Users/bjartur/sleepon go2sleep/staging.py`:

1. **REM and Light are nearly indistinguishable in the emission model.** REM mean HR-z is +0.6 (sd 0.9) against Light 0.0 (sd 1.0),
   and motion and the x10/S-roughness means are almost equal (Light 0.05, REM 0.1). Light has the larger variance, so it wins every
   ambiguous epoch. The self-transitions are almost equal (0.960 vs 0.968), so nothing favours a REM run once it starts.
2. **The HR level is referenced to the whole-night median, not the preceding NREM.** REM HR rises are relative and local: a
   few bpm above the NREM trough of the same cycle (Somers 1993: N3 HR 59 vs wake 64 bpm; REM returns to near-wake levels). A
   whole-night median and a quadratic detrend partly absorb the late-night REM-rich segment. The quadratic can bend up
   at the end and swallow the REM plateaus of cycles 4-5.
3. **The variability feature is wrong for REM.** `std` of epoch-median HR over 5.5 min peaks at *transitions* (the step
   between NREM and REM), not inside a 15-30 min REM plateau. Inside REM, the instability is short-term (seconds to 1 min)
   fluctuation of the 1 Hz HR around its local mean. That needs a high-pass before the std (Walch uses a Difference-of-Gaussians).
4. **There is no ultradian/cycle structure.** The model has no notion of "60-100 min of NREM since the last REM", so nothing
   pushes it to look for REM at 70-120 min after onset or every ~90 min afterwards.
5. **Early-night REM prior.** `0.35 + t/7` is fine in shape, but stacked with points 1-4 it suppresses the first two REM periods entirely.

The fixes are features (section 2), a cycle-aware HMM (section 4.3) and soft proportion calibration (section 4.5).

---

## 1. Published and open-source approaches

| Approach | Inputs | Key features | Reported performance | Portable to our data? |
|---|---|---|---|---|
| **Cole-Kripke 1992** (actigraphy) | 1-min activity counts | D = P·(106A₋₄+54A₋₃+58A₋₂+76A₋₁+230A₀+74A₊₁+67A₊₂) (one published weight set, P=0.001 for max-count mode); sleep if D<1. Webster rescoring rules | Sleep/wake ~88% agreement with PSG; low wake specificity (typically 30-60%) | **Yes**, already used. Our "fraction of seconds with motion" replaces counts, so the threshold must be recalibrated (done: 0.20) |
| **Sadeh 1994** | 1-min counts | PS = 7.601 − 0.065·MEAN₁₁ − 1.08·NAT − 0.056·SD₆ − 0.703·ln(A₀+1); MEAN₁₁ = mean counts over 11-min window centred; NAT = # epochs with 50≤count<100 in that window; SD₆ = sd of last 6 min; sleep if PS ≥ 0 | ~90% agreement in healthy adults; poor wake detection | **Partially.** Its idea that a "moderate-activity count" over 11 min indicates wake ports as "number of motion bursts in ±5 min". The coefficients do not port (count scale) |
| **Oakley 1997** (Actiwatch / Respironics) | 30 s or 1-min counts | Total = A₀ + 0.2·(A₋₁+A₊₁) + 0.04·(A₋₂+A₊₂) for 1-min (30 s version uses ±4 epochs at 1/25, 1/5, …); wake if total > 20 / 40 / 80 (high/med/low sensitivity) | Similar to C-K | **Yes, in structure** (thresholds must be rescaled) |
| **Webster rescoring rules** (1982, used with C-K) | Sleep/wake sequence | (a) after ≥4 min wake, the next 1 min of sleep → wake; (b) after ≥10 min wake, the next 3 min → wake; (c) after ≥15 min wake, the next 4 min → wake; (d) ≤6 min sleep surrounded by ≥10 min wake → wake (≤10 min surrounded by ≥20 min wake → wake) | Improves wake specificity by a few % | **Yes, directly** |
| **van Hees 2018 HDCZA** (GGIR) | Wrist raw accel → arm z-angle | 5 s angle, 5-min rolling median of abs angle change, threshold = 10th percentile × 15 (clamped), keep low blocks >30 min, merge gaps <60 min, longest block = Sleep Period Time (SPT) window | SPT onset/offset within ~30 min of PSG/diary in most nights; no staging | **Concept only.** Use it to find the *main sleep period*: replace angle change with our 5-min motion fraction plus x10 |
| **Walch et al. 2019** (`ojwalch/sleep_classifiers`, Apple Watch + PSG, n=31; MESA test n=188) | Activity counts, PPG HR (bpm every few s), "clock proxy" | **Counts**: per-epoch counts convolved with Gaussian σ=50 s. **HR**: interpolate to 1 Hz → Difference-of-Gaussians band-pass (σ₁=120 s, σ₂=600 s) → divide by the 90th percentile of \|HR − mean sleep HR\| → **std in a window around the epoch** (~10 min). **Clock**: circadian-model drive, or a cosine over the night; time-since-start performed similarly (supplement). LR, kNN, RF, MLP | Sleep/wake: 90% accuracy, wake specificity ~60% at 90% sensitivity. Wake/NREM/REM: ~72% accuracy; with balanced thresholds about 62-65% of NREM and of REM epochs correct (LR motion+HR: 0.625/0.625). κ is low (0.13-0.4; MESA NN motion+HR+clock κ=0.40) | **Most directly portable.** Same type of input: smoothed bpm, not RR. Coefficients are not published in the paper or README (the models are sklearn objects trained at run time). Port the **feature definitions**, not the weights. Expect the same ~65% REM/NREM balanced accuracy at best |
| **Fonseca et al. 2023** (Philips, Sci Rep 13:9182) | Wrist accel activity counts + **PPG inter-beat intervals** → instantaneous HR | Small NN/RNN on IHR + counts (previous version: 100+ HRV features + LSTM) | 4-class κ = 0.638, accuracy 77.8% on a clinical hold-out set | **No** (needs IBIs). Useful as an upper bound for wrist cardiac staging and as evidence that HR + movement alone carries most of the stage information |
| **SleepPPG-Net** (Kotzen et al. 2022, IEEE JBHI; arXiv 2202.05735) | Raw PPG waveform (34 Hz), deep residual + temporal conv net, trained on MESA | End-to-end | 4-class κ ≈ 0.75, accuracy ≈ 84% (MESA) | **No** (needs raw PPG) |
| **sleepecg** (`cbrnr/sleepecg`) | ECG heartbeat times | HRV features per epoch (time and frequency domain) + GRU; pretrained on MESA/SHHS | 4-class κ ≈ 0.6 (ECG) | **No** (needs beats). Its feature list is a good reference if the ring's raw PPG mode ever exposes beats |
| **Oura** (Altini & Kinnunen 2021, Sensors 21:4302) | Ring accel, IBI-based HRV, skin temperature, circadian features; per-night normalisation | GBM | 4-class accuracy 79%, κ ≈ 0.65 against PSG. Accelerometer + temperature + circadian *without* HRV was much worse (~57% 4-class) | Lesson: **per-night normalisation and circadian/time features matter**, and losing HRV costs a lot. Our ring is between those two configurations (HR level and smoothed HR dynamics, no IBI) |
| **Fitbit** (Beattie et al. 2017, Physiol Meas) | Wrist accel + PPG | Movement + HRV-like PPG features, LDA | 4-class accuracy ~69%, κ ≈ 0.52 | No (IBI-based HRV) |
| **Apple** (Sleep Stages white paper, 2023) | Watch accelerometer (motion + respiration from wrist micro-movements) | NN | Reports epoch agreement in the 60-70% range for REM/Deep/Core; no public coefficients | Concept only |
| **Whoop** (published validations ~2020-2022) | Wrist PPG HRV + accel | Proprietary | 2-stage agreement high; 4-stage ~60-65% | No |

**Realistic target for our data (no IBI, no accelerometer counts):** sleep/wake accuracy ~88-90% (wake specificity 40-60%),
3-class (W/NREM/REM) ~65-72%, 4-class κ ≈ 0.3-0.45, and **per-night REM and Deep minutes within ±30-40% of PSG**, which is
the level that matters for a consumer report. Night-level summaries (TST, SE, WASO) are more reliable than epoch labels.

---

## 2. REM detection cues from 1 Hz HR + motion

Physiology (with sources):
- **HR during REM returns to near-wake levels.** Sympathetic activity is 215% of wake (Somers et al., NEJM 1993). N3 is the lowest HR.
  Typical young adult figures from that paper: wake 64, N3 59 bpm. REM is roughly 3-8 bpm (≈ +5-10%) above the NREM trough of the same cycle.
- **HR in REM is irregular.** There are surges, accelerations with phasic REM (eye-movement bursts) and irregular breathing.
  In HRV terms LF/HF goes up. In a 1 Hz smoothed bpm stream this shows up as **larger short-term (15-90 s) fluctuations around the local mean**.
- **Atonia.** Postural muscle tone is lost, so there are **no gross body movements during REM**. Small finger twitches exist but rarely
  trip a motion byte of 5+. Movement clusters at **REM end** (REM periods often terminate in a brief arousal or position change).
- **Ultradian cycle.** Cycles are ~90 min (range 70-120). First REM latency is ~70-120 min after sleep onset (<15 min = SOREMP, pathological
  or sleep-deprived). REM periods lengthen across the night (first ~5-10 min, last 20-40 min). Roughly 4-5 REM periods per night,
  and about 2/3 of REM falls in the second half.
- **SpO2/breathing.** REM has more irregular breathing. In people with any SDB, desaturations cluster in REM. A weak cue, so use it
  only as a minor emission term (desaturation count in ±2 min).

### 2.1 Features (per 30 s epoch *e*; 1 Hz signals with invalid samples interpolated if gaps < 10 s)

| Name | Definition | REM direction |
|---|---|---|
| `hrLocal` | HR median over ±2 epochs (2.5 min) **minus** `hrFloor(e)`, where `hrFloor` = 10th percentile of epoch-median HR over the **preceding 60 min of non-wake epochs** (use whole-sleep 10th pct if <20 min of history). Divide by the night's robust SD of epoch HR (1.4826·MAD over sleep epochs), floor 1.5 bpm | **High** (+0.8 to +1.5) |
| `hrInst` | Walch-style: 1 Hz HR → band-pass = Gauss(σ=10 s) − Gauss(σ=120 s) (removes slow drift, keeps 20 s-2 min fluctuation) → std over ±5 min (21 epochs) → log → night z-score | **High** |
| `hrDoG` | Exactly Walch: DoG(σ₁=120 s, σ₂=600 s) on 1 Hz HR, normalised by the 90th pct of \|HR−mean\|, std over ±5 min | High at REM onsets and offsets; mid in REM. Keep as a secondary feature |
| `stillness` | Seconds since the last motion>0 sample, capped at 1800, at the epoch end → `log1p(sec/60)` | **High** (≥10 min still is typical of mid-REM and of N3) |
| `movBurst` | Count of motion bursts (≥3 consecutive s with motion>0) within ±5 min | ~0 in REM and N3; >0 in Light/Wake |
| `x10z`, `sRoughz` | Mean x10 and mean \|ΔS\| over ±2 epochs, night z-scored on sleep epochs | Your data: lower in deep. Expect REM ≈ Light or slightly higher (irregular breathing) |
| `tSleep` | Hours since sleep onset | Prior |
| `tSinceREM` | Handled inside the HMM state (section 4.3) | Prior |

### 2.2 Concrete REM rules (for a rule-based detector, also used to seed and validate the HMM)

A **REM candidate segment** is a maximal run of non-wake epochs where all of the following hold:
1. `hrLocal` ≥ +0.5 robust SD **and** ≥ +2 bpm above `hrFloor`, for the 5-epoch median.
2. `movBurst` == 0 for ≥ 80% of the segment (atonia). Twitches allowed: a single motion second with no burst.
3. Duration ≥ 10 epochs (5 min). Merge two candidates separated by ≤ 4 epochs (2 min).
4. Start ≥ 60 min after sleep onset (≥ 45 min if the night has a very short latency or is a recovery night). Discard candidates before.
5. ≥ 45 min of NREM since the end of the previous accepted REM segment. If two candidates conflict, keep the one with the larger mean `hrInst`.
6. `hrInst` segment mean ≥ night median (z ≥ 0). This rejects "flat elevated HR" caused by a slow circadian or temperature drift.
7. Bonus confirmation (not required): a motion burst or wake epoch within 3 min **after** the segment end.

Scoring REM by rules alone, then labelling everything else Light/Deep, gives a hypnogram you can compare against the HMM. If they disagree by
>50% in REM minutes, flag the night as "low confidence".

---

## 3. Deep (N3) cues

- **Lowest and most stable HR of the night.** `hrLocal` ≈ 0 to −0.5, the HR floor itself. `hrInst` lowest (z ≈ −1). Regular breathing
  gives a smooth HR. Vagal dominance.
- **No movement.** `movBurst` = 0, long `stillness`. In your data x10 and S-roughness are also lower (z ≈ −0.5).
- **Timing.** N3 is concentrated in the first 1/3 of the night (~60-70% of N3 in the first two cycles). It appears 10-30 min after sleep
  onset and declines with each cycle. It is often absent after ~5 h in adults over 40.
- **Distinguishing N3 from REM** (both still): HR level (N3 low, REM high), HR instability (N3 lowest, REM highest), time since onset,
  and cycle position (N3 early in the cycle, REM at the end).
- **Distinguishing N3 from Light:** Light has more motion bursts and positional shifts, mid HR, and mid instability.
- **Age.** N3 falls ~2%/decade from ~20% at age 20 to ~10% at 60 (Ohayon et al. 2004 meta-analysis). Men lose it faster.

N3 prior per epoch [design choice]: `pDeep(t) = clamp(exp(−t/2.5 h), 0.1, 1)` relative weight, with an extra ×0.5 in the first 10 min after
onset (N3 is rarely reached in <10 min).

---

## 4. Recommended algorithm (Swift-implementable)

### 4.1 Pipeline

```
1 Hz signals ─► validity mask ─► epoching (30 s) ─► Main Sleep Period (SPT) detection
            ─► Wake/Sleep (C-K + Webster + HR-rise check) ─► features (2.1) ─► robust night normalisation
            ─► Cycle-aware HMM (Viterbi, or forward-backward for probabilities) ─► soft proportion calibration
            ─► post-processing rules ─► summaries ─► sanity checks ─► score
```

### 4.2 Pre-processing and wake

1. **Validity:** HR in [35, 130], SpO2 in [70, 100]. An epoch is *unscorable* if <20 valid HR seconds. Interpolate HR gaps ≤10 s, and treat
   longer gaps as invalid. If >2 min of invalid signal runs back-to-back with large `signal_s` jumps, treat it as **off-finger or motion
   artifact → Wake** (if motion is present) or **Unscored**.
2. **SPT window (HDCZA analogue):** a = fraction of seconds moving in a 5-min rolling window. Threshold = max(0.02, 10th pct of a × 15)
   clamped to [0.02, 0.15]. Keep runs below the threshold ≥30 min, merge gaps <60 min, take the longest block → SPT. Epochs outside are Wake (out of bed).
3. **Wake in SPT:** keep your C-K weighted score W > 0.20, then apply **Webster rules** (section 1), then **minimum wake bout 2 epochs**
   (1 min). Add an *HR-rise wake* path: `hrLocal` > +2.5 robust SD for ≥3 epochs **and** `movBurst` ≥1 within ±2 min → Wake
   (catches quiet wake lying still, which C-K misses).
4. **Sleep onset** = first epoch of the first run of ≥ 20 epochs (10 min) with ≥ 18 sleep epochs (AASM-like "persistent sleep"). **Final awakening** = end of the last sleep epoch.

### 4.3 Model: cycle-aware HMM (expanded-state, Erlang-duration chains)

Plain HMM self-transitions give geometric bout lengths and no cycle memory. A semi-Markov structure is emulated by expanding states (cheap: ~40 states × 1000 epochs).

**States**

- `W`: one state.
- `L_k`, `D_k`, k = 0…K−1 (K = 12): Light and Deep while **time since the end of the last REM** (or since sleep onset) is in phase bin k.
  The phase advances stochastically: from any `L_k` or `D_k`, with probability `q = 1/20` per epoch (mean 10 min per bin), go to bin k+1 (same
  stage, or switch stage per the table below). Bin K−1 absorbs (≥ ~110 min).
- `R_m`, m = 0…M−1 (M = 6): REM duration chain. Each REM sub-state lasts a geometric number of epochs (mean 4 epochs = 2 min), so `R_0…R_4`
  enforce a **minimum REM bout of ≈ 5 min in expectation (≥ 5 epochs hard)**. `R_5` is the "mature REM" state with self-transition `s_R(t)`.

**Entry into REM** from `L_k` (not from `D_k`; N3→REM direct is rare) with probability `pLR(k, t)`:

| phase bin k (min since last REM) | 0-30 | 30-50 | 50-70 | 70-90 | 90-110 | ≥110 |
|---|---|---|---|---|---|---|
| `pLR` per epoch | 0.0005 | 0.003 | 0.012 | 0.025 | 0.030 | 0.030 |

Multiply by 0.5 if `tSleep` < 60 min (first REM latency typically ≥70 min). The first cycle uses the bins counted from sleep onset.

**Exit from REM** (`R_5` → `L_0`, phase reset): `1 − s_R(t)`. Mean mature REM bout `= 1/(1−s_R)`: 6 epochs (3 min, plus the 5-min chain = ~8 min) in
the first 2 h, rising linearly to 30 epochs (15 min, plus 5 = ~20 min) after 6 h. So `s_R(t) = 1 − 1/(6 + 24·clamp((tSleep−2)/4, 0, 1))`.
`R_m` → `W` with 0.01 per epoch (REM often ends in a brief awakening).

**Within NREM (per epoch, same k, before phase advance)** [design choice, consistent with typical bout lengths: Light bouts 5-15 min, N3 bouts 10-25 min]:

| from \ to | Light | Deep | REM (= `pLR`) | Wake |
|---|---|---|---|---|
| Light | rest (≈0.93-0.96) | `pLD(t)` = 0.025·exp(−tSleep/3 h) | `pLR(k,t)` | 0.012 |
| Deep | 0.035 | rest (≈0.96) | 0 | 0.004 |
| Wake → | 0.20 | 0.005 | 0.003 | 0.79 (mean bout ~2.5 min) |

Rows are renormalised after adding the phase-advance branch: total mass `q` moves to bin k+1 with the stage distribution of the same row.

**Emissions** (diagonal Gaussian over night-normalised features; Wake epochs are fixed by 4.2, so the HMM emits for W only to let REM end in Wake).
Means and SDs in z units [design choice from physiology, to be refined by EM in 4.4]:

| feature | Light μ (σ) | Deep μ (σ) | REM μ (σ) | Wake μ (σ) |
|---|---|---|---|---|
| `hrLocal` (robust z) | 0.2 (0.8) | −0.4 (0.5) | 1.0 (0.8) | 2.0 (1.2) |
| `hrInst` (z) | 0.0 (0.9) | −1.0 (0.6) | 0.8 (0.9) | 1.2 (1.0) |
| `movBurst` (count, use a Poisson λ) | 0.5 | 0.05 | 0.08 | 3.0 |
| `stillness` log1p(min) | 1.5 (0.9) | 2.4 (0.6) | 2.2 (0.7) | 0.5 (0.6) |
| `x10z` | 0.1 (1.0) | −0.6 (0.8) | 0.1 (1.0) | 1.0 (1.0) |
| `sRoughz` | 0.1 (1.0) | −0.5 (0.8) | 0.1 (1.0) | 1.0 (1.0) |

Weight correlated features down: multiply the log-likelihood of `x10z` and `sRoughz` by 0.5 each, and `stillness` by 0.5 (it overlaps with `movBurst`).
Use **Student-t (ν=4)** instead of Gaussian for `hrLocal`/`hrInst` to tolerate PPG glitches: logpdf = −((ν+1)/2)·log(1 + z²/ν) − log σ.

**Decoding:** run forward-backward to get per-epoch posteriors P(stage). Report the hypnogram as the Viterbi path (consistent bouts) and the posteriors as
confidence. Collapse the expanded states into W/L/D/R.

### 4.4 Unsupervised per-user adaptation (no labels needed)

After ≥5 nights: run Baum-Welch on the user's nights, updating **only emission means** (keep the transitions fixed) with a MAP prior:
μ_new = (n·μ̂ + κ·μ_prior)/(n + κ), κ = 200 epochs. Enforce the ordering constraints after each update: `hrLocal`: Deep < Light < REM;
`hrInst`: Deep < Light ≤ REM. Revert to the priors if the constraints fail. This adapts to a ring whose x10/S scales are idiosyncratic.

### 4.5 Soft proportion calibration (fixes systematic under/over-calling)

After forward-backward, compute the expected REM fraction of TST, `r̂ = Σ P(REM)/N_sleep`. If `r̂` is outside [0.15, 0.27], add a log-bias β to the REM
emission and re-decode. Choose β by bisection in [−1.5, +1.5] so that `r̂` hits the nearest edge of the band, **but cap |β| ≤ 1.0** (at most e¹
≈ 2.7× likelihood). If the cap is hit, keep the result and flag "atypical REM". Do the same for Deep with the band [0.08, 0.25] (age-adjust: upper band 0.25 at age 20, 0.15 at 70).
This is a prior-strength knob, not a forced quota: nights with genuinely little REM (alcohol, short sleep) will stay low.

### 4.6 Post-processing rules

1. Bouts of REM < 3 min (6 epochs) → Light. Isolated Deep < 2 min → Light. Wake runs < 1 min inside sleep → previous stage (count as an arousal).
2. No REM in the first 45 min after sleep onset unless the REM posterior is > 0.8 for ≥ 10 min (flag SOREMP).
3. A Deep epoch directly adjacent to REM: relabel it Light (a ≥1-epoch Light buffer, as in AASM practice).
4. The last 15 min before final awakening cannot be Deep (relabel Light) unless `hrLocal` < −0.5.
5. Unscorable epochs: impute the stage from neighbours if the gap ≤ 3 min, else leave Unscored and exclude from percentages.

### 4.7 Sanity priors (AASM / Ohayon 2004 norms, healthy adults, % of TST)

| Age | TST (h) | SE % | SOL (min) | WASO (min) | N1 % | N2 % | **Light (N1+N2) %** | **Deep (N3) %** | **REM %** | REM latency (min) |
|---|---|---|---|---|---|---|---|---|---|---|
| 20-29 | 7.0-7.5 | 92-95 | 10-15 | 10-20 | 5 | 47-50 | 50-57 | 18-22 | 22-25 | 70-90 |
| 30-39 | 6.8-7.2 | 90-93 | 10-15 | 20-30 | 5-6 | 50 | 55-60 | 15-18 | 21-23 | 70-90 |
| 40-49 | 6.5-7.0 | 88-91 | 12-18 | 30-40 | 6-7 | 52 | 57-62 | 12-15 | 20-22 | 75-95 |
| 50-59 | 6.3-6.8 | 85-89 | 15-20 | 40-50 | 7-8 | 53 | 60-65 | 10-13 | 19-21 | 80-100 |
| 60-69 | 6.0-6.5 | 82-86 | 15-20 | 50-60 | 8-9 | 54 | 62-67 | 8-11 | 18-20 | 80-100 |

Night-level checks to log (already partly in `sanity_check()`): deep_in_first_third ≥ 50%; REM in the second half ≥ 60%; 3-6 REM bouts
≥ 5 min; REM-to-REM onset interval median 70-120 min; REM latency 60-150 min; transitions/h 4-10 (excluding wake blips). The REM-indicator
autocorrelation peak at 80-110 min is good evidence the cycle structure is real.

---

## 5. Oximetry analysis

### 5.1 Definitions (AASM Scoring Manual v2.x)

- **Hypopnea rule 1A (recommended):** airflow drop ≥30% for ≥10 s **with ≥3% desaturation from pre-event baseline** or an arousal.
  **Rule 1B (acceptable, CMS):** same with **≥4%** desaturation.
- **Apnea:** ≥90% airflow drop ≥10 s (no desat requirement).
- **ODI (oxygen desaturation index):** number of desaturations ≥3% (ODI3) or ≥4% (ODI4) below baseline, lasting ≥10 s, **per hour of sleep**
  (per hour of recording if staging is unavailable).
- **AHI severity bands:** <5 normal, 5-15 mild, 15-30 moderate, ≥30 severe. ODI3 tracks AHI(3%) closely in most cohorts (r ≈ 0.9). ODI4
  under-estimates AHI(3%/arousal) by ~30-50%.
- **T90:** % of sleep time with SpO2 < 90%. **Nadir:** lowest valid SpO2 (report after artifact removal; require ≥3 s at that value).
- **Hypoxic burden** (Azarbarzin et al., Eur Heart J 2019): per-event area under the baseline between event-related desaturation windows,
  summed and divided by sleep hours (%·min/h). > ~53 %·min/h is associated with higher CV mortality (top quintile in their data).

### 5.2 Desaturation event detection (1 Hz, ring SpO2)

Ring SpO2 is firmware-averaged (likely 4-8 s windows) and integer-quantised, so dips are smeared and delayed. That favours a 3% criterion
with a slightly relaxed recovery.

```
input: s[t] 1 Hz, valid mask (0/out-of-range → invalid; also invalid if motion>0 within ±3 s or signal_s jump)
s3 = 3-s median filter of s (valid only)
baseline[t] = max( median(s3[t-300 … t-1] valid), ... )      # long baseline: 5-min median
            then baseline_short[t] = 90th percentile of s3[t-120 … t-1]   # pre-event baseline
            B[t] = min(baseline_short[t], baseline_long[t] + 1)            # avoid a single spike setting baseline
scan t:
  if s3[t] <= B[t] - D  (D = 3 for ODI3, 4 for ODI4):
     start = last t' < t where s3[t'] >= B[t] - 1  (walk back ≤ 30 s)
     nadir = argmin s3 over [t, t+120] while not recovered
     recovered at first u > nadir where s3[u] >= nadir + max(2, 0.67·(B - nadir))  or s3[u] >= B - 1
     duration = (time s3 <= B - D … until recovered)   # time below the threshold-crossing point
     accept if 10 s <= duration <= 120 s  and  ≥ 80% of [start, u] valid
     record {start, nadir_time, nadir, depth = B - nadir, dur, area = Σ (B - s3)}
     t = u + 5   (refractory)
```

This follows the relative-baseline approach used in the PhysioZoo oximetry toolbox (`pobm`, Levy et al. 2021). Its `DesaturationsMethods`
include a *relative* method (drop ≥ threshold from a running max over a ~120 s window, length 10-120 s) and a *hard threshold* method.

Outputs: ODI3, ODI4 (events / hour of TST), T90, T88, nadir, mean SpO2 in sleep, desaturation depth/duration distribution, hypoxic burden,
the % of events in REM vs NREM (REM-dominant pattern), and supine-independence (not available).

**AHI-like estimate:** `eAHI = ODI3` (label it "Breathing disturbance index, oximetry-based"). Show bands <5 / 5-15 / 15-30 / ≥30 with a non-diagnostic
disclaimer. Quality-gate it: require ≥4 h of valid SpO2 in sleep.
Optionally refine with HR: count desats that are followed within 30 s by an HR surge ≥ +6 bpm (autonomic arousal) to approximate arousal-linked hypopneas.

---

## 6. Sleep score (0-100)

Public basis: **Oura** has 7 contributors (total sleep, efficiency, restfulness, REM, deep, latency, timing), with bands 85-100 optimal, 70-84 good,
60-69 fair, <60 pay attention, and recommends 7-9 h. **Fitbit** weights duration 50 / quality (deep+REM) 25 / restoration (sleeping HR vs resting HR,
restlessness) 25. **Garmin** uses duration, stress (HRV), stages and restlessness. **Withings** uses duration, depth, regularity and interruptions.
The exact weights and curves are proprietary. The ones below are explicit [design choice] versions in that spirit.

`Score = Σ wᵢ·fᵢ(xᵢ)` with fᵢ ∈ [0, 100] **piecewise-linear between breakpoints (x → f)**. The ends are clamped.

| Component | Weight | Input | Breakpoints (x → f) |
|---|---|---|---|
| Total sleep time | **30** | TST, hours | 3→0, 4→25, 5→50, 6→70, 7→90, 7.5→100, 9→100, 10→85, 11→65, 12→50 |
| Efficiency | **10** | TST / time in SPT, % | 60→0, 70→35, 80→70, 85→85, 90→95, 93→100 |
| Latency | **5** | SOL, min | 0→70, 3→85, 7→100, 20→100, 30→80, 45→50, 60→25, 90→0 |
| Continuity | **15** | 0.6·f(WASO) + 0.4·f(awakenings ≥2 min) | WASO min: 0→100, 10→100, 20→90, 30→80, 45→60, 60→45, 90→20, 120→0. Awakenings: 0→100, 2→100, 4→80, 6→60, 8→40, 12→0 |
| Deep | **10** | Deep minutes (age-adjusted: × 1/(1 − 0.01·max(0, age−30))) | 0→0, 20→25, 40→55, 60→80, 75→95, 90-120→100, 150→90 |
| REM | **10** | REM % of TST | 0→0, 5→15, 10→40, 15→70, 18→90, 20-26→100, 30→90, 35→70 |
| Timing / regularity | **10** | 0.5·f(\|sleep midpoint − personal 14-night median\|) + 0.5·f(midpoint clock time) | Δmidpoint min: 0→100, 15→100, 30→90, 60→70, 90→45, 120→20, 180→0. Midpoint clock: 00:30→70, 02:00-04:00→100, 05:00→70, 06:00→40, 08:00→0 (and 23:00→40, before 22:00→20) |
| Restoration (HR) | **5** | 0.6·f(lowest 5-min sleep HR − personal 14-night median of it) + 0.4·f(time of HR nadir as a fraction of SPT) | Δbpm: −3→100, 0→95, 2→80, 4→60, 7→30, 10→0. Nadir fraction: 0-0.5→100, 0.7→75, 0.9→45, 1.0→30 (late nadir = incomplete recovery, Oura's principle) |
| Breathing / SpO2 | **5** | 0.7·f(ODI3/h) + 0.3·f(T90 %) | ODI3: 0-5→100, 10→80, 15→60, 30→20, 45→0. T90: 0-1→100, 3→80, 5→60, 10→20, 20→0 |
| **Sum** | **100** | | |

Rules:
- **Caps:** if TST < 4 h, score ≤ 50. If TST < 5 h, ≤ 65. If ODI3 ≥ 30, ≤ 70 (it is a health flag, not a sleep-quality detail).
- **Missing components** (no personal baseline yet, SpO2 invalid): drop the component and renormalise the remaining weights to 100.
- **Bands** (same as Oura): ≥85 Optimal, 70-84 Good, 60-69 Fair, <60 Pay attention.
- **Stage-confidence damping:** stage-based components (Deep, REM) are blended toward 75 by (1 − confidence), where confidence = mean max-posterior over
  sleep epochs rescaled from [0.5, 0.9] → [0, 1]. This avoids penalising users for model uncertainty.
- Show each component's sub-score and the input value (transparent score).

---

## 7. Links

Papers
- Walch O, Huang Y, Forger D, Goldstein C. *Sleep stage prediction with raw acceleration and photoplethysmography heart rate data derived from a consumer wearable device.* SLEEP 2019;42(12):zsz180. https://doi.org/10.1093/sleep/zsz180 · full text https://pmc.ncbi.nlm.nih.gov/articles/PMC6930135 · data https://physionet.org/content/sleep-accel/1.0.0/
- Fonseca P, et al. *A computationally efficient algorithm for wearable sleep staging in clinical populations.* Sci Rep 2023;13:9182. https://doi.org/10.1038/s41598-023-36444-2 · https://pmc.ncbi.nlm.nih.gov/articles/PMC10244431
- Kotzen K, et al. *SleepPPG-Net: a deep learning algorithm for robust sleep staging from continuous photoplethysmography.* IEEE JBHI 2023. https://arxiv.org/abs/2202.05735
- Altini M, Kinnunen H. *The Promise of Sleep: A Multi-Sensor Approach for Accurate Sleep Stage Detection Using the Oura Ring.* Sensors 2021;21(13):4302. https://doi.org/10.3390/s21134302
- Beattie Z, et al. *Estimation of sleep stages in a healthy adult population from optical plethysmography and accelerometer signals.* Physiol Meas 2017;38:1968. https://doi.org/10.1088/1361-6579/aa9047
- Cole RJ, Kripke DF, et al. *Automatic sleep/wake identification from wrist activity.* Sleep 1992;15(5):461-469. https://doi.org/10.1093/sleep/15.5.461
- Sadeh A, Sharkey KM, Carskadon MA. *Activity-based sleep-wake identification: an empirical test of methodological issues.* Sleep 1994;17(3):201-207. https://doi.org/10.1093/sleep/17.3.201
- Oakley NR. *Validation with polysomnography of the Sleepwatch sleep/wake scoring algorithm used by the Actiwatch activity monitoring system.* Cambridge Neurotechnology tech. report, 1997.
- Webster JB, et al. *An activity-based sleep monitor system for ambulatory use.* Sleep 1982;5(4):389-399.
- van Hees VT, et al. *Estimating sleep parameters using an accelerometer without sleep diary.* Sci Rep 2018;8:12975. https://doi.org/10.1038/s41598-018-31266-z
- Somers VK, et al. *Sympathetic-nerve activity during sleep in normal subjects.* NEJM 1993;328:303-307. https://pubmed.ncbi.nlm.nih.gov/8419815/
- Ohayon MM, et al. *Meta-analysis of quantitative sleep parameters from childhood to old age in healthy individuals.* Sleep 2004;27(7):1255-1273. https://doi.org/10.1093/sleep/27.7.1255
- Berry RB, et al. *AASM Manual for the Scoring of Sleep and Associated Events*, v2.x (hypopnea rules 1A/1B). https://aasm.org/clinical-resources/scoring-manual/
- Azarbarzin A, et al. *The hypoxic burden of sleep apnoea predicts cardiovascular disease-related mortality.* Eur Heart J 2019;40:1149-1157. https://doi.org/10.1093/eurheartj/ehy624
- Levy J, et al. *Digital oximetry biomarkers for assessing respiratory function: standards of measurement, physiological interpretation, and clinical use.* npj Digit Med 2021;4:1. https://doi.org/10.1038/s41746-020-00373-5

Repositories
- https://github.com/ojwalch/sleep_classifiers (Walch features, sklearn classifiers, Apple Watch + MESA pipelines)
- https://github.com/wadpac/GGIR (van Hees HDCZA / SPT window, sustained inactivity)
- https://github.com/ghammad/pyActigraphy (Cole-Kripke, Sadeh, Oakley, Scripps, Crespo, Roenneberg implementations)
- https://github.com/cbrnr/sleepecg (HR/HRV-based staging, pretrained on MESA/SHHS)
- https://github.com/physiozoo/pobm (oximetry biomarkers: ODI, T90, hypoxic burden, desaturation detection)

Vendor descriptions
- Oura Sleep Score: https://support.ouraring.com/hc/en-us/articles/360025445574-Sleep-Score
- Fitbit Sleep Score: https://support.google.com/fitbit/answer/14236513
- Apple, *Estimating Sleep Stages from Apple Watch* (white paper, Oct 2023): https://www.apple.com/healthcare/docs/site/Estimating_Sleep_Stages_from_Apple_Watch_Oct_2023.pdf
