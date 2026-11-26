import Foundation
import CoreBluetooth
import Observation

@MainActor @Observable
final class RingManager: NSObject {
    enum State: Equatable { case bluetoothOff, unauthorized, idle, scanning, connecting, waking, ready, syncing }

    // Published state
    var state: State = .idle
    var deviceName: String?
    var firmware: String?
    var serial: String?
    var battery: Int?
    var aux: Int?
    var ringClock: Date?
    var clockDriftSec: Double?
    var rssi: Int?
    var live: LiveSample?
    var liveHistory: [LiveSample] = []
    var rawLog: [(date: Date, dir: String, hex: String)] = []
    var syncCount = 0
    var syncLastDate: Date?
    var lastSync: Date? = UserDefaults.standard.object(forKey: "lastSync") as? Date { didSet { UserDefaults.standard.set(lastSync, forKey: "lastSync") } }
    var autoConnect = true { didSet { UserDefaults.standard.set(autoConnect, forKey: "autoConnect") } }
    var autoSetClock = true
    /// Command sent after connecting to request live measurement (best known guess; editable in Lab).
    var liveStartHex = UserDefaults.standard.string(forKey: "liveStartHex") ?? "5a 41 00 01" { didSet { UserDefaults.standard.set(liveStartHex, forKey: "liveStartHex") } }
    var airplaneMode: Bool?
    var monitoringAck: Date?
    /// Keeps the Mac from idle-sleeping while the app is trying to stay connected to the ring (display may still sleep).
    var keepAwake = UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true { didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake"); updateAwake() } }
    var lastWorn: Date?
    var autoHealed: Date?
    private var awakeToken: NSObjectProtocol?
    private var liveBackup: [SecondRecord] = []
    private var lastBackupFlush = Date()
    var sensitivityAck: Date?
    var ringMode: Int?
    var pulse: [Int] = []

    weak var store: DataStore?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var gotFirstFrame = false
    private var syncBuffer: [SecondRecord] = []
    private var lastSyncFrame = Date.distantPast
    private var timers: [Timer] = []

    /// Tells the overnight Python logger (if running) to release the ring while the app uses it.
    private let pauseFile = URL(fileURLWithPath: "/Users/bjartur/sleepon go2sleep/data/overnight/PAUSE")

    override init() {
        super.init()
        autoConnect = CommandLine.arguments.contains("--snapshot") ? false : (UserDefaults.standard.object(forKey: "autoConnect") as? Bool ?? true)
        central = CBCentralManager(delegate: self, queue: .main)
        updateAwake()
    }

    private func updateAwake() {
        let want = keepAwake && autoConnect && !userPaused && !CommandLine.arguments.contains("--snapshot")
        if want, awakeToken == nil {
            awakeToken = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: "Staying connected to the Go2Sleep ring")
            diag("keeping Mac awake while connected to the ring")
        } else if !want, let t = awakeToken { ProcessInfo.processInfo.endActivity(t); awakeToken = nil; diag("released keep-awake") }
    }

    /// Valid live samples are kept as a fallback record of the night; the ring's own history replaces them when synced.
    private func backupLive(_ s: LiveSample) {
        guard s.worn, s.hr > 0 || s.spo2 > 0 else { return }
        liveBackup.append(SecondRecord(t: Int32(s.date.timeIntervalSince1970), hr: UInt8(clamping: s.hr), spo2: UInt8(clamping: s.spo2),
                                       motion: 0, x10: 0, signalS: Int16(clamping: aux ?? 0)))
        if Date().timeIntervalSince(lastBackupFlush) > 300 { flushLiveBackup() }
    }
    func flushLiveBackup() {
        lastBackupFlush = Date()
        guard !liveBackup.isEmpty else { return }
        store?.merge(liveBackup, overwrite: false); diag("saved \(liveBackup.count) live seconds as backup"); liveBackup = []
    }

    /// Morning sync: once the ring has been off the finger for 10 minutes and the last sync is over 6 hours old.
    private func maybeAutoSync() {
        guard state == .ready, live?.worn == false, let w = lastWorn, Date().timeIntervalSince(w) > 600 else { return }
        if let l = lastSync, Date().timeIntervalSince(l) < 6 * 3600 { return }
        diag("ring off finger for 10 min: starting automatic history sync"); syncHistory()
    }

    var statusText: String {
        switch state {
        case .bluetoothOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth permission needed"
        case .idle: "Not connected"
        case .scanning: "Looking for your ring…"
        case .connecting: "Connecting…"
        case .waking: "Waking the ring…"
        case .ready: "Connected"
        case .syncing: "Syncing history…"
        }
    }

    // MARK: public actions
    func connect() {
        userPaused = false; updateAwake()
        guard central.state == .poweredOn else { diag("connect requested but Bluetooth state is \(central.state.rawValue)"); return }
        try? Data().write(to: pauseFile)
        if let p = central.retrieveConnectedPeripherals(withServices: [RingUUID.service]).first(where: { ($0.name ?? "").hasPrefix("Go2Sleep") }) {
            attach(p); return
        }
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// Manual disconnect pauses reconnection for this session only; the saved auto-connect preference is kept.
    private var userPaused = false
    func disconnect() {
        userPaused = true
        updateAwake(); flushLiveBackup()
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        releaseLogger()
    }

    func releaseLogger() { try? FileManager.default.removeItem(at: pauseFile) }

    func send(_ data: Data, label: String = "") {
        guard let p = peripheral, let c = txChar else { return }
        var b = [UInt8](data)
        if b.count > 1, RingCommand.forbidden.contains(b[1]) { log("!!", "refused forbidden command \(RingFrame(bytes: b).hex)"); return }
        if b.count > 1, RingCommand.readOnly.contains(b[1]), b.dropFirst(2).contains(where: { $0 != 0 }) { log("!!", "refused mode write \(RingFrame(bytes: b).hex)"); return }
        // Settings guards: 0x30 (heart/SpO2 monitoring switch) may only be turned ON; 0x50 (trigger sensitivity) only 1...5.
        if b.count > 3, b[1] == 0x30, b[3] != 0x01 { log("!!", "refused: 0x30 may only be set to 01 (on)"); return }
        if b.count > 3, b[1] == 0x50, !(1...5).contains(b[3]) { log("!!", "refused: sensitivity must be 1-5"); return }
        if b.count < 20 { b = [UInt8](RingFrame.pad(b)) }
        let data = Data(b)
        p.writeValue(data, for: c, type: .withResponse)
        log("→", RingFrame(bytes: b).hex + (label.isEmpty ? "" : "  (\(label))"))
    }

    /// Sends a hex string such as "5a 30 00 01".
    func sendHex(_ s: String) {
        let clean = s.replacingOccurrences(of: " ", with: "")
        guard clean.count % 2 == 0 else { return }
        var bytes: [UInt8] = []; var i = clean.startIndex
        while i < clean.endIndex { let j = clean.index(i, offsetBy: 2); guard let v = UInt8(clean[i..<j], radix: 16) else { return }; bytes.append(v); i = j }
        send(Data(bytes))
    }

    func syncClock() { send(RingFrame.setTime(), label: "set clock"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.send(RingFrame.command(0x1d), label: "read clock") } }
    /// The ring streams 0x40 by itself while it detects a finger; 5a 41 00 01 adds the pulse waveform.
    func startLive() { sendHex(liveStartHex) }
    /// Turns the ring's heart-rate/SpO2 sensor switch on (`5a 30 00 01`). The factory state is on; a stray 0 disables auto-measurement.
    func enableSensor() { send(RingFrame.command(0x30, [0x01]), label: "heart/SpO2 sensor ON") }
    /// Trigger sensitivity for automatic monitoring (1 = weakest ... 5 = most sensitive; official default 2).
    var sensitivity = UserDefaults.standard.object(forKey: "sensitivity") as? Int ?? 2 { didSet { UserDefaults.standard.set(sensitivity, forKey: "sensitivity") } }
    func setSensitivity(_ level: Int) { sensitivity = level; send(RingFrame.command(0x50, [UInt8(level)]), label: "trigger sensitivity \(level)") }
    /// Restores automatic monitoring after the ring lost its settings (e.g. flat battery): sensor switch on + sensitivity.
    func restoreAutoMonitoring() {
        enableSensor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.setSensitivity(self.sensitivity) }
    }
    func stopLive() { send(RingFrame.command(0x41, [0x00]), label: "pulse off") }

    func syncHistory() {
        guard state == .ready else { return }
        syncBuffer = []; syncCount = 0; syncLastDate = nil; state = .syncing; lastSyncFrame = Date()
        send(RingFrame.command(0x3c), label: "dump stored seconds")
    }

    // MARK: internals
    private func attach(_ p: CBPeripheral) {
        central.stopScan(); peripheral = p; p.delegate = self; deviceName = p.name; state = .connecting
        central.connect(p)
    }

    private func log(_ dir: String, _ hex: String) {
        rawLog.append((Date(), dir, hex)); if rawLog.count > 3000 { rawLog.removeFirst(rawLog.count - 3000) }
        Diagnostics.shared.write("\(dir) \(hex)")
    }
    private func diag(_ s: String) { log("··", s) }

    private func writeStatus() {
        var d: [String: Any] = ["t": ISO8601DateFormatter().string(from: Date()), "state": "\(state)", "autoConnect": autoConnect, "userPaused": userPaused,
                                "gotFirstFrame": gotFirstFrame, "txReady": txChar != nil, "peripheralState": peripheral?.state.rawValue ?? -1]
        d["battery"] = battery; d["rssi"] = rssi; d["firmware"] = firmware; d["serial"] = serial
        d["clockDriftSec"] = clockDriftSec; d["syncCount"] = syncCount
        if let l = live { d["live"] = ["spo2": l.spo2, "hr": l.hr, "worn": l.worn, "charging": l.charging, "pi": l.pi, "age": Int(-l.date.timeIntervalSinceNow)] }
        d["liveValid10min"] = liveHistory.filter { $0.valid && $0.date.timeIntervalSinceNow > -600 }.count
        d["pulseSamples"] = pulse.count
        Diagnostics.shared.status(d)
    }

    private func startTimers() {
        timers.forEach { $0.invalidate() }
        timers = [Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }]
    }

    private var tickCount = 0
    private func tick() {
        tickCount += 1
        writeStatus()
        if tickCount % 30 == 0 { maybeAutoSync() }
        if state == .waking && !gotFirstFrame { send(RingFrame.command(0x15, [0x00]), label: "wake") }
        if state == .ready, tickCount % 60 == 0 { send(RingFrame.command(0x15, [0x00])) }
        if state == .syncing, Date().timeIntervalSince(lastSyncFrame) > (syncCount == 0 ? 25 : 6) { finishSync() }
        if let p = peripheral, p.state == .connected, tickCount % 5 == 0 { p.readRSSI() }
    }

    private func onReady() {
        state = .ready
        // Same order as the official app: clock, battery, version, serial, airplane mode; plus ring-mode read.
        let seq: [(Data, String)] = [(RingFrame.command(0x1d), "clock"), (RingFrame.command(0x15), "battery"), (RingFrame.command(0x14), "firmware"),
                                      (RingFrame.command(0x03), "serial")]
        for (i, c) in seq.enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(i)) { self.send(c.0, label: c.1) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.startLive() }
    }

    private func finishSync() {
        state = .ready; lastSync = Date()
        store?.merge(syncBuffer)
        log("✓", "history sync finished: \(syncBuffer.count) records")
        syncBuffer = []
    }

    private func handle(_ bytes: [UInt8]) {
        guard bytes.count >= 2, bytes[0] == 0x5b else { log("←", RingFrame(bytes: bytes).hex); return }
        let f = RingFrame(bytes: bytes)
        if !gotFirstFrame { gotFirstFrame = true; if state == .waking { onReady() } }
        switch f.cmd {
        case 0x3c:
            if let r = RingParser.secondRecord(f) { syncBuffer.append(r); syncCount += 1; syncLastDate = Date(timeIntervalSince1970: TimeInterval(r.t)); lastSyncFrame = Date() }
            return   // too many to log individually
        case 0x40:
            if let s = RingParser.live(f) {
                live = s; liveHistory.append(s); if liveHistory.count > 1800 { liveHistory.removeFirst(liveHistory.count - 1800) }
                if s.worn { lastWorn = s.date }
                backupLive(s)
            }
        case 0x15:
            if bytes.count > 3 { battery = Int(bytes[3]) }
            if bytes.count >= 11 { aux = (Int(bytes[9]) << 8) | Int(bytes[10]) }
        case 0x41:
            pulse.append(contentsOf: bytes.dropFirst(2).prefix(10).map(Int.init)); if pulse.count > 600 { pulse.removeFirst(pulse.count - 600) }
            return
        case 0x54: airplaneMode = bytes[2] != 0
        case 0x52: if bytes.count > 3 { ringMode = Int(bytes[3]) }
        case 0x30: monitoringAck = Date()
        case 0x50: sensitivityAck = Date()
        case 0x14: firmware = RingParser.ascii(f)
        case 0x03: serial = RingParser.ascii(f)
        case 0x1d:
            if let d = RingParser.date(bytes[3...]) {
                ringClock = d; clockDriftSec = d.timeIntervalSinceNow
                // A clock that is hours off means the ring lost power and reset: its auto-monitoring settings are gone too.
                if abs(clockDriftSec ?? 0) > 6 * 3600 {
                    diag("ring clock is \(Int((clockDriftSec ?? 0) / 3600)) h off: ring was reset (power loss); restoring auto-monitoring")
                    autoHealed = Date(); restoreAutoMonitoring()
                }
                if autoSetClock, abs(clockDriftSec ?? 0) > 30 { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.syncClock() } }
            }
        default: break
        }
        if f.cmd != 0x40 && f.cmd != 0x15 { log("←", f.hex) }
        else if rawLog.last?.hex != f.hex { log("←", f.hex) }
    }
}

extension RingManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        MainActor.assumeIsolated {
            switch c.state {
            case .poweredOn: state = .idle; diag("Bluetooth powered on; autoConnect=\(autoConnect)"); if autoConnect { connect() }
            case .unauthorized: state = .unauthorized
            default: state = .bluetoothOff
            }
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        MainActor.assumeIsolated {
            let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? ""
            let uuids = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
            if name.hasPrefix("Go2Sleep") || uuids.contains(RingUUID.service) { self.rssi = rssi.intValue; diag("discovered \(name) rssi \(rssi)"); attach(p) }
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated { state = .waking; gotFirstFrame = false; diag("connected; discovering services"); p.discoverServices([RingUUID.service]) }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { state = .idle; log("!!", "connect failed: \(error?.localizedDescription ?? "?")"); retry() }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            if state == .syncing { finishSync() }
            flushLiveBackup()
            state = .idle; txChar = nil; log("!!", "disconnected: \(error?.localizedDescription ?? "no error")"); timers.forEach { $0.invalidate() }; writeStatus()
            retry()
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            diag("services: \((p.services ?? []).map { $0.uuid.uuidString }) error: \(error?.localizedDescription ?? "none")")
            for s in p.services ?? [] where s.uuid == RingUUID.service { p.discoverCharacteristics([RingUUID.tx, RingUUID.rx], for: s) }
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            diag("characteristics: \((s.characteristics ?? []).map { $0.uuid.uuidString }) error: \(error?.localizedDescription ?? "none")")
            for c in s.characteristics ?? [] {
                if c.uuid == RingUUID.tx { txChar = c }
                if c.uuid == RingUUID.rx { p.setNotifyValue(true, for: c) }
            }
            startTimers()
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let v = c.value else { return }
        let bytes = [UInt8](v)
        MainActor.assumeIsolated { handle(bytes) }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { diag("notify \(c.uuid.uuidString) on=\(c.isNotifying) error: \(error?.localizedDescription ?? "none")") }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error { MainActor.assumeIsolated { diag("write error: \(error.localizedDescription)") } }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated { rssi = RSSI.intValue }
    }

    private func retry() {
        guard autoConnect, !userPaused else { releaseLogger(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.state == .idle, self.autoConnect, !self.userPaused else { return }
            self.connect()
        }
    }
}
