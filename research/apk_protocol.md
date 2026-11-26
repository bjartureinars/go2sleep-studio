# Go2Sleep BLE protocol as implemented by the SLEEPON Android app

Source: static decompilation (jadx) of **SLEEPON** `com.sleep.on` **v2.4.20** (versionCode 205),
APK from Aptoide's Play mirror (`com-sleep-on-205-...apk`, MD5 `324863bbde10b78b7e126356d0e0c51b`).
Uptodown also lists 2.4.20 as the latest release.

- APK: `research/apk/com.sleep.on-2.4.20.apk`
- Decompiled: `research/apk/decompiled/sources/com/sleep/on/...`. The BLE code is in `blue/control/`, `MainActivity.java`,
  `ui/BleCmdActivity.java` and `ui/ring/*`.
- **No native libraries.** The APK has no `lib/` directory, so there is nothing to run `strings` on. All BLE logic is in Java.
- BLE stack: `com.clj.fastble` (FastBle) plus the Nordic DFU library (`no.nordicsemi.android.dfu`).

The Developer account on Google Play also publishes **SLEEPON 3** (`com.sleepon.sleepon3`, first released in June 2024, last updated in July 2025).
Its listing also names the Go2sleep ring. I could not download it: Aptoide doesn't carry it, APKCombo shows a
Cloudflare "verify you are human" challenge, and APKPure blocks with a bot check. I did not try to get past those challenges.
Firmware V6.x may follow SLEEPON 3's protocol in places. In particular, the 0x3C record format you observed does
**not** match the (dead) 0x3C parser in this app. See section d.

---

## 0. Transport and framing (applies to everything)

`blue/control/BleConstant.java`:
```java
UUID_NUS_SERVICE   = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
UUID_NUS_CHARACTER = "6e400002-..."   // write
UUID_NUS_NOTIFY    = "6e400003-..."   // notify
UUID_NUS_DESCRIPTOR= "00002902-..."   // CCCD
```

* **Every host command is a 20-byte array, zero-padded.** `BleSend.sendCommand` always starts from
  `byte[] lightColor = new byte[20];` and fills in only the leading bytes. It writes the whole 20 bytes with
  `BleManager.write(...)`, using the characteristic's default write type (FastBle default, no MTU change, no write-without-response override).
  **If your probes sent short frames (e.g. `5a 41 00 01`), that is the most likely reason
  some commands got no reply. Always send exactly 20 bytes.**
* Layout: `[0]=0x5A, [1]=cmd, [2]=status/sub-op (normally 0), [3..]=args, rest 0`.
* Ring replies: `[0]=0x5B, [1]=cmd, [2]=status/packet-no, [3..19]=data`. The app turns the reply into an
  action string `"ACTION"+hex(byte[1])` (`BleReply.dealReplyData`) and broadcasts it.
* **Checksum** (`BleString.bytesCheckAnd` / `isCheckAnd`): a u16 **big-endian** sum of bytes 0..17, stored in bytes 18..19.
  - Host side: only **SET_BLE_TIME (0x1E)** carries a checksum. The app computes it over the 20-byte buffer before
    bytes 18 and 19 are filled, so it is effectively the sum of bytes 0..17.
  - Ring side: the app verifies the checksum on 0x38 summary, 0x42 hour packets ≥1, 0x3B minute packets ≥1, and 0x3C packets ≥1.
  ```java
  int iShift = shift(arrayList.get(18), arrayList.get(19));   // (b18<<8)|b19
  for (int i = 0; i < 18; i++) sum += arrayList.get(i);       // includes 0x5B and cmd
  ```
* No length byte and no CRC beyond this sum.

## g. Pairing / bonding / auth

* **None.** There is no `createBond`, no auth handshake, no key exchange, and no MTU request. The scan list is filtered by
  name (`"Go2Sleep"` = ring, `"Go2Silence"` = sleep ball) and by the NUS UUID (`UUID_FILTER`). The app then connects
  directly (`BleUtils.connect`) and enables notify on 6e400003 500 ms after `onConnectSuccess` (`BleCallbackConnect`).
* "Unbind" in the app calls the hidden `BluetoothDevice.removeBond()` on the phone side and sends nothing to the ring.
* On first pairing, `BleConnectActivity` sends `5a 22 00…` (OPEN_SHAKE, vibrate). The int argument (4) is ignored
  for this command, so the frame is just `5a 22` plus 18 zeros.

---

## a. Command table (exact 20-byte frames the app builds, `blue/control/BleSend.java`)

`XX` = argument, rest of the 20 bytes = 00.

| cmd | name in app | host frame (first bytes; rest 00) | used by app? | reply parsing (ring → host) |
|---|---|---|---|---|
| 02 | BLE_TYPE | `5a 02` | never sent | – (makes your ring disconnect; avoid) |
| 03 | BLE_SN | `5a 03` | yes, on connect | `doSn`: bytes 3..19 ASCII (zeros skipped) |
| 0b | HISTORY_SLEEP_INDEX | `5a 0b` | **never sent** (legacy) | – |
| 0c | HISTORY_STEPS_DATA | `5a 0c 00 XX` | never sent | – |
| 0f | CURRENT_HEART | `5a 0f` | never sent | – |
| 12 | REAL_HEART_SWITCH | `5a 12 00 XX` | **never sent** (legacy) | – |
| 14 | BLE_VERSION | `5a 14` | yes | `doVersion`: bytes 4..19 ASCII → "V"+str |
| 15 | BLE_BATTERY | `5a 15` | yes | byte3 = battery % |
| 1b | CLEAR_BLE_FLASH | `5a 1b 00 XX` | never sent | **DANGEROUS** |
| 1d | GET_BLE_TIME | `5a 1d` | yes, first command after notify enabled | b3=yy(−2000) b4=mm b5=dd b6=hh b7=mi b8=ss |
| 1e | SET_BLE_TIME | `5a 1e 00 yy mm dd hh mi ss 00…00 CKH CKL` | yes | reply triggers alarm config (0x34) |
| 1f | BLE_RESET | `5a 1f` | "Restore" button | **DANGEROUS – factory restore** |
| 20 | OPEN_LIGHT_COLOR | `5a 20 00 R G B` | not for ring | – |
| 21 | CLOSE_LIGHT | `5a 21` | – | – |
| 22 | OPEN_SHAKE | `5a 22` | on pairing (vibrate) | – |
| 23 | CLOSE_SHAKE | `5a 23` | – | – |
| 25 | SHAKE_MODE | fixed: `5a 25 00 00 02 00 00 03 01 f4 01 f4 00…` | not called | – |
| 29 | SENSOR_RATE | `5a 29` | never | – |
| 30 | HEART_SPO2_SWITCH | `5a 30 00 XX` | **never sent**; reply ignored (`BleCmdActivity` returns on ACTION30) | – |
| 32 | WRITE_SN | `5a 32 00 <ASCII…>` | never (factory) | **DANGEROUS** |
| 33 | BLE_RESTART | `5a 33` | never | **DANGEROUS (reboot)** |
| 34 | BLE_CLOCK (alarm) | read: `5a 34 00`; write: see below | yes | see `doAlarmClock` |
| 35 | CLEAR_FLASH_DATA | `5a 35 00 00` | **yes, automatically after every successful sync** | **DANGEROUS – erases stored sleep data** |
| 38 | HISTORY_SUMMARY | `5a 38 00` | yes, starts the sync | see section d |
| 3b | RING_MINUTE_DATA | `5a 3b 00 IDXH IDXL` | yes | see section d |
| 3c | SECOND_DATA | `5a 3c 00 IDXH IDXL` | code exists but **dead** (never dispatched) | see section d |
| 3e | RING_MINUTE_INDEX | `5a 3e 00` | yes | b3..4 = u16 number of minute-data indexes (nights) |
| 3f | BALL_MINUTE_INDEX | `5a 3f 00` | **Go2Silence only** (not a ring "second index") | – |
| 40 | HEART_SPO2 | (ring → host only, unsolicited) | – | see section c |
| 41 | PULSE | `5a 41 00 01` start / `5a 41 00 00` stop | yes, real-time screen | see section c |
| 42 | RING_HOUR_DATA | `5a 42 00` | yes | see section d |
| 43 | SpO2 alarm config / LOW_OXYGEN | `5a 43 OP EN` (OP: 0=get, 1=set; EN 0/1) | yes | b3 = state |
| 44 | SHAKE | `5a 44` | "Find device" (vibrate). Also sent on notify-enable if a pref is set | on reply the app sends 5a 1d |
| 47/4a/4b–4e/49 | ball-only | – | Go2Silence | – |
| 50 | SENSITIVE | `5a 50 00 XX` | ball | – |
| 51 | SPO2_THRESHOLD | `5a 51 00 XX` (XX = % trigger, default 88) | yes | – |
| 52 | DEVICE_SE | `5a 52 00 XX`, XX: 0=query, 1=normal ring ("side"), 2="SE/fingertip" | yes (query after version) | b3 = current mode (1 or 2) |
| 53 | FLIGHT_SET (airplane mode) | `5a 53 00 XX` (1=on, 0=off) | toggle in device page | – |
| 54 | FLIGHT_GET | `5a 54 00` | yes, on connect | **b2** (status position) = 1 if airplane mode on |
| e0 | FM_RESET | `5a e0` | yes, after sync FINISH | `doDeviceReset`: b3..6 = u32 BE "reset reason"; the app then sends `5a e1` |
| e1 | FM_ERROR | `5a e1` | yes | `doDeviceError`: b2 = chunk no., b3..19 ASCII "error location"; complete when b2==5 |

Alarm write (`BleSend.sendClockConfig`, called with i=3):
```
5a 34 01 00 00 03 HH MM mon tue wed thu fri sat sun 01 EN 00 00 00
```
(Byte 2 = 1 means write. Day bytes are 0/1, from bitmask `week`: 1, 0x10, 0x100, … 0x1000000.)
Alarm read reply (`doAlarmClock`, only when b2==0): b3 = count, b4 = index, b6 = hh, b7 = mm, b8..14 = day flags, b16 = enabled.

SET_BLE_TIME exactly (`BleSend.setDeviceTime`):
```java
bArr[0]=90; bArr[1]=0x1e; bArr[2]=0; bArr[3]=yyyy-2000; bArr[4]=MM; bArr[5]=dd; bArr[6]=HH; bArr[7]=mm; bArr[8]=ss;
int ck = BleString.bytesCheckAnd(bArr);  bArr[18]=(ck>>8)&255; bArr[19]=ck&255;
```
e.g. 2026-11-25 10:00:00 → `5a 1e 00 1a 0b 19 0a 00 00 00…00 00 c0` (sum = 0x5a+0x1e+0x1a+0x0b+0x19+0x0a = 192 = 0x00c0).

---

## b. Sequence right after connecting

1. `connect()` → `onConnectSuccess` → after **500 ms**, enable notifications on 6e400003 (`BleCallbackConnect`).
2. `onNotifySuccess` (`BleCallbackNotify`):
   ```java
   if (BleUtils.isNotifySwitch(ctx)) sendCommand(ACTION_SHAKE)        // 5a 44 (normally false)
   else                              sendCommand(ACTION_GET_BLE_TIME)  // 5a 1d
   ```
3. Reply `5b 1d …` → `doDeviceTime` → **always** sends SET_BLE_TIME `5a 1e 00 yy mm dd hh mi ss … ck ck` with phone time.
   (If the drift is over 1 h, the app reports "device restarted" to the server.)
4. Reply `5b 1e` → if an alarm is stored, it sends `5a 34 01 …` (alarm config).
5. In parallel, `MainActivity` CONNECTED → `BaseActivity.sendBleCmd()` timers:
   - +200 ms `5a 15` battery
   - +250 ms `5a 14` version (reply → firmware-update HTTP check)
   - +300 ms `5a 03` SN
   - +400 ms `5a 54 00` airplane-mode get
   - +500 ms `5a 34 00` alarm read
   - +600 ms `5a 43 00 00` SpO2-alarm config read
6. `RingHomeFragment` CONNECTED, after **1000 ms**: **if the ring is not worn and no sync is running**, it sends
   `5a 38 00` and the history sync starts (section d). If `isWearing` (from the last 0x40 frame's wear flag) is true, the sync is skipped.
7. The device-settings page sends `5a 14`, then `5a 52 00 00` (SE query), then `5a 54 00`.

No user-info, no handshake/auth, no "mode" command.

---

## c. Real-time heart rate / SpO2 (the important part)

### What the app does
**The app has no "start measurement" command for HR/SpO2.** It never sends 0x12, 0x0F or 0x30.
The 0x40 frames are an **unsolicited status stream** from the ring. The app just listens to them wherever it is
(the home screen shows live HR/SpO2 from them).

Real-time screen (`ui/ring/RingRealTimeActivity.java`):
```java
initData():  BleSend.sendCommand(ctx, ACTION_BLE_BATTERY, null, "");   // 5a 15 00 00 … (20 B)
onResume():  BleSend.sendCommand(ctx, ACTION_PULSE, 1, "");            // 5a 41 00 01 00…00 (20 B)
onPause():   BleSend.sendCommand(ctx, ACTION_PULSE, 0, "");            // 5a 41 00 00 00…00 (20 B)
```
`BleSend` case for ACTION_PULSE:
```java
lightColor[0]=90; lightColor[1]=65 /*0x41*/; lightColor[2]=0; lightColor[3]=(byte)iIntValue;
```
So the only "start live" frame is **`5a 41 00 01` + 16 × `00` (20 bytes total)**, and stop is `5a 41 00 00` + 16 × `00`.
There is no checksum, no precondition command, no timer and no keep-alive. The battery request is sent once on entry.
The 0x41 command switches on the **PPG pulse waveform** frames (`5b 41`). The 0x40 HR/SpO2 frames come anyway.

### 0x40 frame (`MainActivity.doHeartSpo2`, `RingRealTimeActivity.doBleCallBack`)
```
5b 40 ST  b3=SpO2 %  b4=HR bpm  b5=wear (1=worn)  b6=charging (1=on charger)  b7=PI level (0..4, optional)
```
```java
int spo2 = a.get(3), heart = a.get(4), wear = a.get(5), charge = a.get(6);
int pi = a.size() > 7 ? a.get(7) : 0;          // perfusion index bucket → icon ic_pi_0..4
int rr = 60000 / heart;  hrv = |rr - lastRr| clamped to [10,70]   // "HRV" is computed in the app from successive HR
```
App display logic:
- If `heart<=0 || spo2<=0`, it shows "--".
- If `wear==1`, it waits **5 s after the wear flag goes from 0 to 1** (`mWearingBefore`, `isWaitEnd`), then shows the values.
- If `wear==0`, it shows "not worn" and draws zeros.

So all-zero 0x40 frames with `b5=0` mean **the ring itself reports "not worn"**. The firmware is not measuring.
Nothing the app sends changes this. It is the ring's own on-finger detection.
Your single good frame `5b 40 00 62 3c 01 00 1d` decodes as SpO2=98, HR=60, wear=1, charging=0, PI byte=0x1d.
The app only maps PI 1..4 to icons, so 0x1d would display as PI 0. That byte may be something else on V6 firmware.

### 0x41 pulse frame (`RingRealTimeActivity`, `BleState.PULSE`)
```
5b 41 b2..b11 = 10 PPG waveform samples (unsigned bytes), drawn as-is
```
```java
for (i=0;i<10;i++) fArr[i] = arrayList.get(i + 2);   // requires size >= 12
```
Samples are drawn only when worn and after the 5 s settle. Note that the samples start at **byte 2**, so no status byte is used here.

### Things the app does that may matter for your reproduction attempt
1. **20-byte writes.** Send `5a 41 00 01` padded to 20 bytes, and `5a 15` padded to 20 bytes.
2. **Airplane mode (0x53/0x54).** The app reads it on every connect (`5a 54 00` → reply byte 2 = flag). The home screen
   ignores 0x40 frames while `isFlight`, and the toggle is disabled while worn. Airplane mode probably makes the
   ring stop radio/sensor activity. Check it with `5a 54 00` (read-only) and, if it is 1, clear it with `5a 53 00 00`.
3. **SE/fingertip mode (0x52).** `5a 52 00 00` queries it: reply b3 = 1 for the normal ring and 2 for "Go2Sleep SE / fingertip".
   The app warns that SE mode needs special firmware ("fingertip_version" dialog). If your ring reports 2, wear detection
   or the optics may be configured for a different sensor position. That is a plausible cause of a permanent wear=0
   (an inference, not proven). The app sets it with `5a 52 00 01` (normal) or `5a 52 00 02` (SE).
4. The app does **not** run history sync while the ring is worn, and it ignores 0x40 during a sync (`isDataSynchronizing`).
   Don't run 0x3C dumps while trying to get live data.
5. 0x30 HEART_SPO2_SWITCH exists in the constants, but the app **never sends it** and ignores its reply.
   The same is true for 0x12 and 0x0F. They are probably obsolete.

---

## d. History sync (ring = Go2Sleep)

Triggered on connect if not worn. The chain lives in `MainActivity.doHistorySummary` → `doHourRing` → `doMinuteIndex` → `doMinuteRing`.
The **year is never sent by the ring**. The app uses the phone's current year.

### 1) `5a 38 00` → summaries (0x38), 3 packets per night, checksum verified
Common: b2 = packet number (0,1,2), b3 = night index, b4 = night count.
- **pkt 0:** b6=start MM, b7=DD, b8=hh, b9=mi; b11=end MM, b12=DD, b13=hh, b14=mi; b15=**sleep score**; b16..17=in-bed minutes (u16 BE).
- **pkt 1:** u16 BE pairs: b5-6 awake ("bedActive"), b7-8 asleep ("bedSleep"), b9-10 REM, b11-12 N1, b13-14 N2, b15-16 N3 (minutes).
- **pkt 2:** b5-6 N4/deep (u16), b7 HR avg, b8 HR max, b9 HR min, b10 SpO2 avg, b11 SpO2 max, b12 SpO2 min, b13 **AHI count**, b14 flip/turn count.
- b18..19 = checksum (sum of b0..17).

When `index == count` the app sends `5a 42 00` (hour data). The ring appears to stream all summaries in response to one 0x38. The app sends no per-index requests.

### 2) `5a 42 00` → hourly data (0x42)
- **pkt 0 (b2=0):** b3=index, b4=index count, b6..9 = start MM DD hh mi, b11..14 = end MM DD hh mi, b15 = number of hours,
  b16 = number of data packets, b17 = "synchronize" flag.
- **pkt n≥1 (checksum verified):** 6 hours per packet. AHI events/hour are at b5, b7, b9, b11, b13, b15. Flips/hour are at b6, b8, …, b16.
  Hour slot = (n−1)*6 + k.
- After the last packet of the last index, the app sends `5a 3e 00`.

### 3) `5a 3e 00` → minute index (0x3E)
- b3..4 = u16 BE number of minute-data blocks (nights). If 0, the sync finishes. Otherwise the app sends `5a 3b 00 00 01`.

### 4) `5a 3b 00 IDXH IDXL` → minute data (0x3B), 1-based index
- **pkt 0 (b2..3 = 0):** b4..5 = index, b7=MM, b8=DD, b9=hh, b10=mi (start), b11..12 = number of minutes (u16 BE),
  b13..14 = number of packets (u16 BE), b17 = synchronize flag.
- **pkt n≥1 (b2..3 = n, checksum verified):** 3 minutes × 4 bytes at b6..17:
  `[heartBpm, spo2 %, state, sport]` for minutes (n−1)*3+0..2.
  On a checksum failure the app re-requests the same index.
- Next index: `5a 3b 00 (idx+1)` once the last packet arrives (or right after pkt 0 if synchronize==0).
- When `index == count`, the app uploads to the server **and then sends `5a 35 00 00` (CLEAR_FLASH_DATA), which wipes the ring's stored data.**
  Then it sends FM_RESET `5a e0` → `5a e1`.

**`state` values (per-minute sleep stage, computed on the ring)** from `widget/MarkerDay.java` and `bean/Simulate.java`:
`2` = awake, `3`/`4` = light (N1/N2), `5` = REM, `6`/`7` = deep. Sleep onset = first minute with state 3.
`sport` = movement level (the UI clamps it to 0..100).

### 5) 0x3C second data: the app's (dead) parser
`doSecondDataIndex` / `doSecondData` exist in `MainActivity` but are **never called**. ACTION3c is in the intent
filter but not dispatched, and 0x3F is the ball's minute index, not a ring "second index". Their format, for reference
(identical framing to 0x3B):
- Request `5a 3c 00 IDXH IDXL` (index 1-based).
- pkt 0: b2..3 = 0, b4..5 = index, b7..11 = MM DD hh mi **ss**, b12..15 = u32 BE sample count (seconds), b16..17 = u16 packets, b18 = synchronize.
- pkt n≥1: 3 seconds × 4 bytes at b6..17 (fields not named in the code; by analogy heart, spo2, state, sport), b18..19 checksum.

**This does not match what your V6.3.15 ring sends** (a self-timestamped 20-byte record per frame,
dumped in full by `5a 3c 00`). Your firmware uses a newer 0x3C layout that this app version doesn't use.
Byte meanings beyond HR/SpO2 for that layout cannot be determined from this APK. SLEEPON 3 might have them.

---

## e. Algorithms / server

* **Sleep staging, score and AHI are computed on the ring.** The app receives the score (0x38 b15), stage minutes,
  per-minute state, per-hour AHI and the AHI count ready-made. The Java code has no staging, AHI or SpO2 algorithm, and there is
  no native code. The app only derives simple things: "HRV" in the live view = |Δ(60000/HR)| clamped to 10..70,
  sleep latency (first state==3), and the awake count and duration (`bean/Simulate.java`).
* Data is uploaded to SleepOn servers but not analysed there for staging. Base URLs (`http/HttpConstants.java`/`HttpRequest`):
  `https://en.sleepon.us/api/`, `https://cn.sleepon.cn/api/`, `https://ja.sleepon.us/api/`.
  Endpoints include `Sleep/uploadDataV1` (summary + `ss_ahi_times`, `ss_state_raw`, `ss_sport_raw`, heart and SpO2 raw arrays),
  `Sleep/getDataV1`, `Sleep/countDataV1`, `Sleep/delDataV1`, `Hardware/getFirmwareVersion` (DFU package check, type "121"),
  `App/throwError` (error reports, including checksum failures and ring reset reasons), `App/isUpdate`, plus user, friend, label, goal and VIP endpoints.
  None were called.

## f. Commands never to send

| frame | why |
|---|---|
| `5a 35 00 00` CLEAR_FLASH_DATA | erases stored sleep data (the app sends it after every sync) |
| `5a 1b 00 XX` CLEAR_BLE_FLASH | flash erase |
| `5a 1f` BLE_RESET | "Restore factory settings" (`device_restore_cmd` dialog) |
| `5a 33` BLE_RESTART | reboot |
| `5a 32 00 <sn>` WRITE_SN | overwrites the serial number |
| `5a 02` BLE_TYPE | your ring disconnects; the app never sends it |
| `5a e0` / `5a e1` | the app uses them only to read the last reset reason and error location (looks read-only), but they are firmware-diagnostic. Treat with care |
| `5a 52 00 01/02`, `5a 53 00 01` | change persistent modes (SE/fingertip, airplane). Only the query forms `5a 52 00 00` and `5a 54 00` are read-only |
| DFU | via Nordic buttonless Secure DFU on service 0xFE59 (`BleUpgradeActivity`: `DfuServiceInitiator … setUnsafeExperimentalButtonlessServiceInSecureDfuEnabled(true)`). Never write to 0xFE59 |
