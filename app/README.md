# Go2Sleep Studio

A native macOS app (SwiftUI + Swift Charts + CoreBluetooth) for the SleepOn Go2Sleep ring.
It talks to the ring directly, with no SleepOn account or phone, and analyses sleep on-device.

## Run
- Installed copy: `/Applications/Go2Sleep Studio.app` (signed with your Apple Development certificate, which already has Bluetooth permission).
- Open in Xcode: `app/Go2SleepStudio.xcodeproj` (generated from `app/project.yml` by `xcodegen generate`).
- Command-line build: `xcodebuild -project Go2SleepStudio.xcodeproj -scheme Go2SleepStudio -configuration Release -derivedDataPath build.noindex build`

## Features
- **Live**: SpO2, heart rate, pulse strength, worn flag, battery, RSSI, live chart and pulse waveform (`5a 41 00 01`).
- **Nights**: sleep score with breakdown, hypnogram (Awake/REM/Light/Deep), stage breakdown, heart rate with resting line,
  SpO2 with shaded desaturations (ODI, T90, nadir), movement, PDF export.
- **Trends**: score, stage hours, resting HR, ODI, lowest SpO2 per night, 7-night sleep debt against a goal.
- **Device**: serial, firmware, battery, ring clock and drift (auto-synced), history sync (`5a 3c` dump), CSV import/export.
- **Lab**: raw command console and frame log. Erase/reset/vibrate/light/mode-write commands are blocked in code.
- **Menu bar**: live heart rate and SpO2, last night's score.

## Data
- Stored per-second records: `~/Library/Application Support/Go2SleepStudio/records.bin` (10 bytes per second).
- First launch imports `data/history_seconds.csv` from this project.

## Protocol notes
See `research/apk_protocol.md` (decompiled official app) and the memory notes. Key points: every host command is 20 bytes,
zero padded (`5a cmd 00 args…`); the ring streams `5b 40` live frames by itself while it detects a finger; never send `5a 35`
(the official app erases the ring's history after each sync).

## Headless verification
`"Go2Sleep Studio.app/Contents/MacOS/Go2SleepStudio" --snapshot <dir>` (launch with `open -n … --args`) renders the main
screens to PNG, a sample PDF report, and `nights.json` with all computed metrics, then quits.
