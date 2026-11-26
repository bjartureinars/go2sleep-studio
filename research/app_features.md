# SleepOn / Go2Sleep official app: feature inventory

Compiled 2026-11-25. This document lists what the official SLEEPON apps do, so we can rebuild the features in our macOS SwiftUI app.

**Sources, and how much to trust each one**
- **[APK]**: the decompiled official Android app `com.sleep.on` v2.4.20 in `research/apk/decompiled/`. This is the strongest source: UI strings, the scoring code, thresholds, colours and BLE commands are taken from it directly. This is the "SLEEPON 2.x" app. Its iOS twin is App Store id 1385995937.
- **[S3]**: the SLEEPON 3 app (App Store id 6497714109), which is required for Go2sleep 3 and firmware V4+/V6+. It was not decompiled, so it is known only from listings, the changelog and the vendor's comparison table. Our ring runs firmware V6.3.15, which makes it a Go2sleep 3-class device.
- Web pages are listed at the end and cited inline as [n].

---

## 0. App structure (2.x, from the APK)

The bottom tabs are **Sleep** (home), **Report**, **Improve**, **Discover** and **Me** (`tab_home`, `tab_report`, `tab_improve`, `tab_discover`, `tab_mine`).

**Onboarding flow**
1. Login or register with email or phone (4-digit SMS code), Facebook, WeChat or Apple ID.
2. Accept the privacy and service agreement.
3. Profile: date of birth, gender, height and weight ("to have accurate report").
4. "Do you have a GO2SLEEP?" (Yes / Buy one).
5. Activate the ring by putting it on the charger; the red LED comes on.
6. Connect the ring. Scan, choose from the device list, then confirm "Is your ring vibrating?" yes/no. The serial number is printed on the package.
7. Wear guide, in 3 steps:
   1. "Pull down to synchronize the data."
   2. "Wear the ring on the knuckles of your finger."
   3. "It vibrates twice, the light on the bottom turns on. GO2SLEEP starts working."

**Home ("Sleep" tab)**
- Greeting ("Good morning…").
- "Today's Sleep" cards.
- "Sleep of Family" cards.
- Pull-to-refresh, which runs the BLE sync ("Release to synchronize data").
- A banner, "Please take off the go2sleep to synchronize the data", shown while the ring is worn.
- "Last Update" timestamp.
- Live tiles: Current HR, Current SpO2 and PI.

**Home card management ("Sort Cards")**: drag to reorder, and show or hide each card. The cards are:
- Sleep Time
- Sleep Stage
- Oxygen Level
- Heart Rate
- HRV
- Sleep Apnea
- Toss and Turn
- Sleep Debts
- Sleep Label

**Report tab**
- Day / Week / Month segmented control, plus a calendar ("CalendarView") and "Back to today".
- "My Report", with a score and tips text.
- Each card opens a detail screen.
- "View minute report" opens a minute-resolution chart.
- "Sleep Chart" has an indicator picker: "You can choose the indicators you need for comparative analysis".
- Landscape mode is supported for charts.
- Multi-segment sleep: "Multi-segment sleep" separators, plus a per-night "Data sources" selector (choose the device and time slot).

**Me tab**
- Profile: avatar, nickname, DOB, gender, height and weight.
- My device.
- Biological Alarm.
- Low Oxygen Alert.
- Sleep goals.
- Family.
- Settings:
  - Units: cm/ft-inch and kg/lb.
  - Font size S/M/L.
  - Night Mode.
  - Language: EN, DE, JA, PL, zh-Hans, zh-Hant.
  - Privacy.
  - About.
- Account binding.
- Change password.
- Clear all data.
- Delete account.
- Feedback (with log upload and screenshot).
- Help: Guidance for beginners, Instructions, FAQs, Terminology, Contact us.
- Activate VIP (Basic vs Premium editions, with activation codes).
- "Plugin" (beta) features page.

**Improve and Discover tabs**: Sleep Diary, sleep labels with label comparison, tutorials and articles (web content).

---

## 1. Features in detail

### 1.1 Pairing and device management

**Pairing**
- BLE scan, then a device list, then connect. The ring confirms with a green LED flash and 2 vibrations [1][APK].
- On Android, Location and Nearby Devices permissions are required.
- Only one phone can be bound at a time. The app says: "Your device bond with another phone, please unbind first".

**Troubleshooting checklist**: no power, bound to another phone, too far away (keep it within 10 m), Location permission missing.

**Device screen ("My device")**
- Firmware version.
- Device time ("Device Time").
- Battery: a low-battery warning prompt, "Battery:%s".
- Flight mode toggle. In flight mode the ring stops BLE; to exit it, take the ring off and press the button. Added in 2.2.6 as "automatic flight mode when wearing" [AppStore 2.x].
- Unbind.
- Clear firmware data (flash).
- Reset to factory settings, which clears device data; the ring must then be recharged and re-activated.
- "Switch SE firmware version" for the fingertip holder variant.
- **Find Your Ring**: an RSSI-based simulated distance ("The device is about you") plus a "Let the ring vibrate" button [APK][2].

**S3 additions**
- "Monitoring Selection: Manual mode / Automatic mode" (added in 3.0.6; 3.0.7 per one source). In Manual mode you start and stop monitoring yourself.
- "Sensitivity adjustment" for automatic mode [S3 changelog][9].

The trigger-sensitivity concept already exists in 2.x: "Trigger sensitivity refers to the threshold of the trigger (activates the sensor). The weaker sensitivity is less likely to be triggered…", with a Weak ↔ More sensitive slider.

**Multi-device**
- Multiple rings can be linked to one account [7].
- "Data Setup" sets device priority. When two devices output the same data, the higher-priority one wins.
- The Go2silence positional device is supported as a second device type.

### 1.2 Firmware update (OTA)

- Uses Nordic DFU (service 0xFE59) with a progress percentage.
- Requirements: the ring must be connected, the battery must be at least 30% ("The firmware power is less than 30% and cannot be upgraded"), and the ring must stay near the phone and not be moved.
- Retry, Skip and Ask Help buttons.
- The server checks the latest version via `Hardware/getFirmwareVersion`.
- Old firmware gates "plugin" features: "Firmware version is too old".

### 1.3 Real-time measurement (live HR / SpO2 / PI / HRV / pulse wave)

**Real-time screen (`RingRealTimeActivity`)**
- Clock with seconds.
- Battery with a charging icon.
- Connection state.
- Large numbers for Heart Rate, Blood Oxygen, Pulse rate and HRV, with Lottie heart and SpO2 animations.
- Scrolling waveforms: WaveHeart, WaveSpo2, WaveHrv and WavePulse (the PPG pulse wave).
- A "clock" view and a "wave" view that switch, with landscape support ("Please placed the phone horizontally…").
- Keeps the screen awake (FLAG_KEEP_SCREEN_ON).

**PI (perfusion index)**: "the signal strength of the device to detect finger joints. It is recommended that the PI index be above two grids". It is shown as a bar or grid meter.

**HRV in live view**: |60000/HR − previous|, clamped to 10–70.

**Behaviour**
- If the ring is not worn, the screen shows "The device is not worn".
- After the ring is put on, the app waits about 5 s ("Monitoring...") before showing values.

**How the app drives live mode (2.x protocol, for our BLE work)**
- On screen resume it sends `ACTION_PULSE` = `5a 41 00 01`, zero-padded to **20 bytes**.
- On pause it sends `5a 41 00 00`.
- The ring answers with `HEART_SPO2` frames (`5b 40 …`): idx3 = SpO2, idx4 = HR, idx5 = worn (1/0), idx6 = charging (1/0), idx7 = PI.
- `PULSE` frames (`5b 41 …`) carry 10 waveform samples at idx2..11.
- The app also sends `ACTION_BLE_BATTERY` (`5a 15`) on open.
- Every command is a fixed **20-byte** frame written to the Nordic UART (NUS) characteristic. Set-time additionally carries a 16-bit additive checksum in bytes 18–19 (`BleString.bytesCheckAnd`).
- Code: `research/apk/decompiled/sources/com/sleep/on/ui/ring/RingRealTimeActivity.java` and `.../blue/control/BleSend.java`.
- This may explain our unsolved live stream: our probes may have sent short frames, or not sent `41 01` as a 20-byte write. Caveat: our firmware V6 is an S3-era device, and S3 may differ.

**Other relevant opcodes**
- 0x12 real-heart switch
- 0x30 HR/SpO2 switch
- 0x43 SpO2 alert config
- 0x51 SpO2 threshold
- 0x50 sensitivity
- 0x53/0x54 flight mode set/get
- 0x20 LED colour (RGB)
- 0x21 LED off
- 0x22/0x23 shake on/off
- 0x25 shake mode
- 0x34 alarm (clock) config
- 0x38 history summary
- 0x3b/0x3e ring minute data/index
- 0x42 ring hour data
- 0x3c second data
- 0x35 clear flash
- 0x1e/0x1d set/get time

How long real-time mode lasts: in the 2.x app it is purely screen-scoped (on while the screen is open, off on leave). No ring-side timeout is documented.

### 1.4 Recording start/stop, sync, charging, battery, storage (point 3)

**Start**
- **Automatic when worn.** The vendor FAQ says: "Hold the device gently (clench your fist), it will vibrate twice and start to work" [1].
- The app guide says it "vibrates twice, the light on the bottom turns on. GO2SLEEP starts working" [APK].
- Reviews also say it "starts working automatically once you slip it on" [3][7].
- The report's "Start Time" is defined as "The time when you wear and turn on Go2sleep" [APK].
- S3 adds a Manual mode (the user starts and stops monitoring in the app), plus sensitivity for the auto-trigger [S3][9].

**Stop**: removing the ring stops monitoring. "When you take off the ring, it stops monitoring and starts generating reports. So you need to take off the ring to synchronize data" [1]. The app refuses to sync while the ring is worn ("Please take off the go2sleep to synchronize the data") [APK].

**Sync**
- Pull down on the home screen.
- Sync the time before wearing: "If the battery runs out and is recharged, the device restarts and resets its time", which causes missing or garbled data. Reconnect before each night [1].
- The phone can be off overnight; the ring records standalone [1][3].

**Sessions**
- Several sessions per night are stored as segments ("Multi-segment sleep") and merged into a day.
- Users report problems with nights that are split or merged incorrectly [AppStore reviews].

**Charging**
- Magnetic dock. Original model: mini-USB. Go2sleep 3: USB-C.
- A full charge takes about 2 h [1][4].
- First placement on the charger activates the ring (red flash).

**LEDs**
- Red flashing: charging.
- Green steady: full.
- Orange: recharging after self-drain on the dock.
- Green flash plus 2 vibrations: connected to the app.
- Red flashing continuously while on the finger: storage full [1].

**Battery life**
- Go2sleep / SE: about 3 nights.
- Go2sleep 3: about 2 nights [4][5].
- Shorter if used more than 8 h a day or with the SpO2 alert on [6].
- The Low-O2 alert needs the battery above 80% when it is switched on [APK][3].
- OTA needs the battery at 30% or more [APK].

**Storage (on the ring)**
- Go2sleep / SE: 4 Mbit flash, "7 days", minute-level storage. The FAQ says "about 30 hours ≈ 3 nights at 10 h"; the HST page says 24 h.
- Go2sleep 3: 16 Mbit, "more than 8 days", second-level storage. Transfer takes about 2.5 min per 8 h of data, versus about 10 s on the original model [5].
- Our dump of 9 nights (14–23 Nov) is consistent with this.
- Cloud storage is unlimited ("lifelong") [4].

**Sampling**: 50 Hz PPG at 660 nm / 940 nm, reported per second [4][6].

### 1.5 Sleep report: metrics, definitions, thresholds (2.x code and strings)

All of the following is from the APK unless a source is cited. In the 2.x data path, stages, AHI count and toss counts come **from the ring's summary and hour frames**; the app then aggregates them.

| Metric | Definition (official text, paraphrased or quoted) | Thresholds / bands used in UI |
|---|---|---|
| **Sleep Score** (0–100) | Client-side formula, see 1.6 | 0–39 Awful, 40–59 Below average, 60–79 Normal, 80–89 Good, ≥90 Excellent ("You beat more than 90% people!"). Bar colours: ≤40 red, 41–60 yellow `#fbbc05`, >60 teal `#00b9ad` |
| **Sleep Time** | "duration from the time falling asleep to wake up time. 7–9 h is the average needed for adults" | ≤300 min "less than 5 hours"; 301–419 too short; 420–539 normal; ≥540 too long. Bars: ≥450 min purple `#52469f`, else yellow |
| **Time in Bed** (total recording time) | From wearing the ring to taking it off | — |
| **Total Sleep Time / Actual sleep** | "total sleep time minus the awake time" | — |
| **Sleep efficiency** | "ratio of total sleep time to time in bed" | — |
| **Sleep latency** | "from the moment you go to bed to the moment you actually fall asleep" | — |
| **WASO / Time Awake** | "time awake after sleep onset but before final awakening" | — |
| **Number of wakes** | Awakenings during the night | — |
| **Sleep Onset / Wake Up** | Sleep-in and wake times; "Sleep Architecture" module (2.4.3) | — |
| **Sleep Stages** | Originally 6 (N1, N2, N3, N4, REM, Awake); reduced to 4 displayed (Awake, Light = N1+N2, Deep = N3+N4, REM) in 2.3.5 | Deep% (N3+N4 of total) ≤13 "too short", 14–22 normal, ≥23 good. Colours: Deep `#254aa0`, Light `#548bf7`, REM `#8ec2fa`, Wake `#fbbc05` |
| **Oxygen Level (SpO2)** | "ratio between oxygenated haemoglobin and total haemoglobin" | Avg, Lowest, Highest; **"SpO2 distribution"**: Low SpO2 Ratio vs Normal Ratio, using the **88% cutoff** (`AVG_SPO2 = 88`); state labels Normal / Alert / Danger. Colours normal `#44b9fb`, notice `#fbbc05` |
| **Heart Rate** | "heart rate per minute during sleep"; resting HR = average in the sleep stage | Avg ≤50 "Bradycardia… professional check recommended"; 51–90 normal; >90 "High". Avg, min, max |
| **HRV** | "standard deviation of the heartbeat interval" (SDNN-like); added in 2.4.0 | HRV chart with min/max limits |
| **Sleep Apnea / AHI** | "AHI(Apnea and hypopnea index)… AHI<5 normal; 5–15 mild ('moderate light'); 15–30 moderate ('moderate severe'); ≥30 severe". Computed as **AHI = (sum of hourly apnea events) × 60 / total sleep minutes**. Events are counted by the ring firmware (SpO2-desaturation based; no airflow) | Day bars: ≤5 teal, ≤15 yellow, >15 red. Week/month bars use 35/105. Also "Apnea" = total apnea+hypopnea count per night |
| **ODI** (S3) | ODI 3% (AASM) and ODI 4% (CMS) both reported; "ODI ≥4" display; hourly ODI (v2) → second-level ODI (S3) [5][8] | Risk shown as a percentage [4] |
| **Toss and Turn** | "total times of body movement during sleep"; also "Toss and turn amplitude… sum of the amplitudes of the swings per minute" and "Motion Intensity" on the chart | Per hour: ≤8 normal, 9–15 "beyond average", >15 too many. Colour orange `#ff9227`. Units times/h, times/d |
| **Sleep Debt** | "deficient sleep hours of the last six days" = Σ(sleep − goal); goal defaults to **450 min (7.5 h)** | ≤−120 min "lack of sleep"; −120…−60 "not good enough"; −60…+60 normal; >+60 good. Colours teal / yellow |
| **Sleep posture** (Go2silence only) | Left, right, back, stomach, standing; supine ratio; turn count; 3D replay | — |

**Report presentation**
- A daily summary card with score and tips. The tips are auto-generated sentences that combine the per-metric texts above, e.g. "Your sleep is normal, yet there is room… ; However, AHI is 7.2, you might have moderate light sleep apnea…".
- Each metric has a detail page with:
  - "Actual Value" vs "Standard range" (comparison to normal).
  - A day line or area chart at minute resolution.
  - A week/month bar chart coloured by threshold.
  - Avg / Lowest / Highest.
  - An explanation popup ("Terminology").
- Disclaimer on charts: "The sleep chart is for reference only, not for diagnosis or medical treatment."
- Masking: "Masked data" can be excluded from weekly and monthly averages and later restored.
- Single records can be deleted.

### 1.6 Sleep score algorithm (exact, from `bean/Algorithm.getRingScore`)

Inputs:
- N1, N2, N3, N4 and REM minutes.
- `T` = sum of those minutes.
- ahiCount, flipCount, avgSpO2, and the start hour `h`.

Scoring steps, in order:
1. **Duration (max 56)**
   - 420 ≤ T ≤ 540: 56.
   - T < 420: ⌊T/30⌋ × 4.
   - T > 540: 56 − 4·⌊(T−540)/30⌋, or 0 if more than 7 h over.
2. **Bedtime (max 10)**
   - h in 21–23: +10.
   - h in 16–20: +10 − 2·(21−h).
   - h in 0–4: +10 − 2·(h+1).
   - Otherwise: 0.
3. **Stage proportions (+1 each)**
   - N1 2–5%
   - N2 45–55%
   - N3 3–8%
   - N4 10–15%
   - REM 20–25%
4. **AHI (max 14)**: with AHI = ahiCount·60/T,
   - AHI ≤ 5: +14.
   - AHI ≤ 33: +14 − (AHI−5)/2.
5. **Toss per hour (max 10)**: with x = flip·60/T,
   - x ≤ 8: +10.
   - x ≤ 28: +10 − (x−8)/2.
6. **SpO2**: avg SpO2 ≥ 94 adds +5.
7. **Cap**: the total is capped at 100.

The Go2silence variant uses +2 per stage band and different apnea and turn weights.

### 1.7 Trends (Day / Week / Month)

- Report tab Week and Month views show bar charts per metric, coloured by threshold: score, sleep time, stages (stacked), AHI, toss, HR, SpO2, HRV and debt.
- They also show average lines for sleep start and wake times.
- A calendar view [3].
- S3 lists "Trends (enhanced)" and a Web Dashboard [5].

### 1.8 Vibration features ("shake")

- **Low Oxygen Alert** ("Dangerous oxygen reminding"):
  - When SpO2 drops below the **trigger preset value**, the ring vibrates to wake you or prompt a position change.
  - The slider runs **70–92%, default 88%**.
  - Requires the battery above 80% when enabled.
  - Note in the app: "Frequent vibration reminders will increase power consumption."
  - One user reports 3 vibrations per alert [8].
  - S3 re-added the "low blood oxygen alert" in 3.0.2, requiring firmware 4.1.6 [S3].
- **Vibration intensity and frequency settings**: intensity Weak ↔ Strong; frequency in "min/times".
- **Supine reminder** (Go2silence): vibrates when you are on your back.
- The Go2sleep 3 marketing mentions "positional feedback that gently vibrates" [10].
- **Biological Alarm** (smart alarm): "the device will wake you up during the alarm period while in light sleep state". It has a time, a window, and repeat options (Never / every day / weekdays / weekend / custom days). It is sent to the ring as `5a 34 01 …` with 7 day flags.
- **Find My Ring**: vibrates on demand.
- **Feedback vibrations**: 2 on start, 2 on connect.

### 1.9 LED

The ring LED is used for status (see 1.4). The protocol also has `ACTION_OPEN_LIGHT_COLOR` (`5a 20 R G B`) and `CLOSE_LIGHT` (0x21), so the LED colour can be set. No user-facing LED colour setting was found in the 2.x strings, so this is probably used for debugging or confirmation.

### 1.10 Sleep goals, diary, labels

**Sleep goal**
- Weekly sleep target and wake-up time.
- "Depending on your age, it is recommended that you sleep 7–9 hours".
- A sleep debt preview.
- Restore defaults.
- The goal drives the sleep debt calculation and the sleep time bar colours.

**Sleep Diary (2.4.4+)**
- Done in two steps: "Complete in the morning" (last night's sleep and wake-up feeling) and "Complete at the end of day" (daytime factors).
- Bed and wake times can be edited.
- Caffeine and alcohol intake is logged with timing: before breakfast, after breakfast, after lunch, after dinner, in the hour before sleep.
- Other factors: cigarettes, exercise, naps, medications, bath, reading, relaxation, electronics, headache, fatigue.
- Free text and photos.
- The app frames it as the premise of CBT-I.

**Sleep Labels / Tags**
- Tag nights with labels.
- "Label Comparison" picks 2 labels (A and B) and compares their effect on sleep.
- S3 adds "Analysis of sleep factors" [5].

### 1.11 Data export

- **2.x**: monthly CSV export ("all sleep data, and sleep tags") saved to a SLEEPON folder. Minute-level CSV.
- **PDF report export** exists in both apps per the vendor table [5]. The A4-layout PDF is described on [11].
- **S3**: second-level and day CSV, minute CSV, PDF. A second-level PDF is under development.
- **Desktop "SLEEPON View"** (Win/Mac): imports the CSV, draws minute charts, and exports printable images [6].

### 1.12 Sharing

- **Family / "Health moment"**:
  - Add family members by user ID.
  - Accept invitations.
  - Set remark names, pin to top, set who can see my report.
  - Get report-update notifications.
  - Shows "This month's score" and "Sleep Profile" per member.
  - Requires agreeing to a Data Sharing Agreement.
- **Report share**: an image or web link with a QR code ("My sleep report at SLEEPON"), via `Share/createShareLoadUrl`.
- **SLEEPON Care**: a B2B web platform for clinics, companies and researchers [12]:
  - Multi-user management, groups, integrated reports.
  - CSV export of selected users.
  - User consent required.
  - Planned: OAuth2 developer platform and a BLE-gateway real-time feed.
  - There is no consumer "doctor" app. "Share with your doctor" means exporting the PDF or CSV, or using the web report [7][10].
- **Web dashboard**: sleepon-cloud.sleepon.us (S3).

### 1.13 Health integrations

- **2.x iOS**: Apple Health sync of HR, SpO2 and sleep after authorization [AppStore 2.x].
- **Android**: Google Fit permission strings ("Activity data is used as part of the Google Fit API").
- **S3**: HealthKit initially missing; the developer said it was "in progress", then fixed in 3.0.5. Reviews say syncing is unreliable [S3 reviews].

### 1.14 Settings and account

- Units (height cm/ft, weight kg/lb).
- Font size.
- Night mode (dark).
- Language.
- Profile.
- Password and email change.
- Account binding (Email / Phone / Facebook / WeChat / Apple).
- Region server reassignment when the language changes.
- Clear all sleep data.
- Delete account (2.4.11).
- VIP / Premium activation code.
- Force-update prompt.

### 1.15 S3-only and planned features [5][4][S3]

**Available in S3**
- Sleep Health Assessment (PSQI questionnaire).
- AI analysis and personalized recommendations, "sleep self-coaching".
- Sleep factors analysis.
- Second-level ODI.
- Web dashboard.
- Data migration from 2.0.

**Planned ("under development")**
- Scientific sleep debt.
- Second-level PDF.
- SpO2 vs ODI≥4 plot.
- Blood glucose estimate (listed as "coming soon").
- White noise ("Forest Sleep FM").
- Continuous BP.
- Real-time data logging.
- Manual data calibration.
- Personalized sleep guide.

**Known S3 problems (reviews)**: sync failures, "no data" mornings, split or merged nights, and missing AHI screen on the Go2sleep 3 (it shows ODI instead) [8].

---

## 2. Prioritized feature list for our macOS app

### Must-have (parity with the core)
1. **Device management**: scan and connect, battery, firmware version, serial number, set the ring clock on every connect (critical; time-reset bug), and "take ring off to sync" guidance.
2. **History sync**: pull all per-second records (0x3c). Show progress, keep data locally (no cloud needed), and support incremental sync by index. Ask before clearing flash.
3. **Night segmentation**: build sessions from worn/time gaps, merge multi-segment nights into one "sleep day" (noon-to-noon), and allow manual split or merge.
4. **Night report**:
   - Time in bed, TST, latency, WASO, number of wakes, efficiency.
   - SpO2: avg, min, max, time below 90% and 88%, a distribution histogram.
   - ODI 3% and 4% with an event list.
   - Estimated AHI and severity band.
   - HR: avg, min, max, resting.
   - HRV.
   - Movement / toss count per hour.
   - Hypnogram (4 stages, our own staging).
   - Sleep score, using the SleepOn formula for comparability plus our own transparent score.
5. **Minute and second-level charts** with zoom and pan. Synchronized SpO2 + HR + motion + stage tracks; desaturation events shaded.
6. **Trends**: week, month and year bars, coloured by threshold, with averages; a calendar heatmap.
7. **Live view**: HR, SpO2, PI (bars), pulse waveform and worn/charging state, if we can enable the stream (`5a 41 00 01`, 20-byte frame).
8. **Export**: CSV (second, minute and night summary) and a one-page PDF A4 "doctor report".
9. **Settings**: low-SpO2 alert threshold (70–92, default 88) with on/off and the battery caveat; sleep goal (default 7.5 h); units.

### Nice-to-have
- Smart / biological alarm (light-sleep window) and Find My Ring vibrate, once the opcodes are confirmed on V6 firmware.
- Sleep diary and tags, plus A/B tag comparison (with statistics).
- Sleep debt (rolling 6 or 14 days).
- Apple Health write: HR, SpO2 and sleep stages via HealthKit on macOS 14+, or a companion approach.
- Flight mode toggle, sensitivity setting, Manual/Auto monitoring mode.
- Firmware OTA. Low priority and risky; leave it to the official app.
- Menu-bar widget: last night's score, ring battery, sync status.
- Night mode is automatic on macOS.

### Where we can do better
- **Transparency**: show how every number is computed. Use ODI by 3%/4% with a rolling 120 s baseline and a 10 s minimum duration, and label AHI as "estimated (SpO2-based)". The official app gives no method and its banding has bugs (in the decompiled tip logic the mild, moderate and severe branches are unreachable or mislabelled).
- **No account or cloud**, works offline, privacy by default; the official app requires login and region servers.
- **Reliable night assembly**: users' top complaints are lost, split and "no data" nights. Keep raw data immutable and re-derive reports.
- **Signal quality**: use the per-second signal/PI to mask artifacts and show coverage percentage; exclude low-quality SpO2 from minimum and ODI.
- **Clinical-style PDF**: SpO2 histogram, desaturation table, T90/T88, hourly ODI, a positional note, plus the disclaimer.
- **Multi-night comparison and correlations**: tags vs score, ODI vs sleep position or alcohol, HRV trend.
- **Bulk CSV/Parquet export and a scriptable data folder** (data/ already exists).
- **Better staging**: combine HR, HRV and motion in our own algorithm, with the vendor's ring-computed stages (if any in V6) as a comparison.

---

## 3. Sources

[APK] Official SLEEPON Android app 2.4.20, decompiled. Local: `research/apk/decompiled/`. Key files:
- `resources/res/values/strings.xml` and `colors.xml`
- `sources/com/sleep/on/bean/Algorithm.java` (score and tips)
- `bean/Simulate.java` (AHI, debt, SpO2 88%)
- `ui/Spo2TriggerActivity.java` (70–92, default 88)
- `ui/ring/RingRealTimeActivity.java` (live mode)
- `blue/control/BleSend.java` and `BleConstant.java` (opcodes)

[AppStore 2.x] SleepOn, id1385995937 (features and version history): https://apps.apple.com/us/app/sleepon/id1385995937
[S3] SLEEPON 3, id6497714109 (changelog 3.0.0–3.0.13, reviews): https://apps.apple.com/us/app/sleepon-3/id6497714109

1. SLEEPON Quick Guide / FAQ: https://www.sleepon.us/?p=15 and https://www.sleepon.us/support/
2. SLEEPON's Go2sleep review page: https://www.sleepon.us/sleepon-go2sleep-review/
3. Sleep Foundation review: https://www.sleepfoundation.org/best-sleep-trackers/sleepon-go2sleep-review
4. Go2sleep 3 shop page (specs): https://shop.sleepon.us/collections/sleepon-life/products/go2sleep-v3
5. Go2sleep 3 page with Go2sleep / SE / 3 and SLEEPON vs SLEEPON 3 comparison tables: https://www.sleepon.us/?p=14897
6. GO2SLEEP (HST) page, including SLEEPON View desktop and specs: https://www.sleepon.us/?p=16
7. The Fitness Junkie Blog review: https://www.thefitnessjunkieblog.com/reviews/sleepon-go2sleep-ring
8. ODI 3% vs 4% article: https://www.sleepon.us/the-reason-why-sleepon-provides-odi-3-and-odi-4/ (and user comments on the review pages)
9. Third-party Go2sleep 3 usage guide (manual/auto mode path "Mine > Devices > Monitoring Selection"): https://milled.com/sleeponhealth/the-correct-usage-steps-of-go2sleep-3-FypoVix1kvQPi_hR (403 to our fetcher; quoted via search snippet)
10. SLEEPON article on Go2Sleep 3 (positional vibration, sharing with providers): https://www.sleepon.us/?p=17185
11. SLEEPON App 3 page: https://sleeponhealth.com/pages/app-1
12. SLEEPON Care: https://www.sleepon.us/?p=7153
13. SLEEPON 3.0 update notice: https://www.sleepon.us/?p=6461
14. Digital Trends (2017, PI and movement metrics): https://www.digitaltrends.com/wearables/go2sleep-sleep-apnea/
15. ManualsLib excerpt (box contents, LEDs): https://www.manualslib.com/manual/3413715/Screen-Sleepon-Go2sleep.html
