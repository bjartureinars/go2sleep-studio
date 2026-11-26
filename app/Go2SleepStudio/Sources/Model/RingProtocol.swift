import Foundation
import CoreBluetooth

/// Go2Sleep ring wire protocol (Nordic UART service).
/// Host -> ring:  5a <cmd> <status=00> <payload...>
/// Ring -> host:  5b <cmd> <status> <payload...>
enum RingUUID {
    static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let tx = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")      // write
    static let rx = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")      // notify
}

enum RingCommand: UInt8, CaseIterable {
    case bleType = 0x02, serial = 0x03, historySleepIndex = 0x0b, historySteps = 0x0c, currentHeart = 0x0f
    case realHeartSwitch = 0x12, version = 0x14, battery = 0x15, clearBleFlash = 0x1b, getTime = 0x1d
    case setTime = 0x1e, reset = 0x1f, openLight = 0x20, closeLight = 0x21, openShake = 0x22, closeShake = 0x23
    case shakeMode = 0x25, sensorRate = 0x29, heartSpO2Switch = 0x30, writeSerial = 0x32, restart = 0x33
    case clock = 0x34, clearFlashData = 0x35, historySummary = 0x38, minuteData = 0x3b, secondData = 0x3c
    case minuteIndex = 0x3e, secondIndex = 0x3f, heartSpO2 = 0x40, pulse = 0x41, hourAHI = 0x42
    case lowOxygen = 0x43, shake = 0x44, fmReset = 0xe0, fmError = 0xe1

    /// Commands that erase data, reset, rewrite identity, drop the link, or actuate the ring.
    static let forbidden: Set<UInt8> = [0x02, 0x1b, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x12, 0x32, 0x33, 0x35, 0x53, 0x54, 0xe0, 0xe1]   // 0x54 drops the link on fw V6.3.15
    /// 0x34 (alarm) and 0x52 (ring/fingertip mode) are allowed only as reads: `5a xx 00 00`.
    static let readOnly: Set<UInt8> = [0x34, 0x52]

    var name: String { String(describing: self) }
}

struct RingFrame {
    let bytes: [UInt8]
    var cmd: UInt8 { bytes.count > 1 ? bytes[1] : 0 }
    var status: UInt8 { bytes.count > 2 ? bytes[2] : 0 }
    var hex: String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }

    /// Every host command is exactly 20 bytes, zero padded (as the official app does).
    static func command(_ cmd: UInt8, _ payload: [UInt8] = []) -> Data { pad([0x5a, cmd, 0x00] + payload) }
    static func pad(_ b: [UInt8]) -> Data { Data(Array((b + [UInt8](repeating: 0, count: 20)).prefix(20))) }
    /// Set clock; bytes 18-19 carry a big-endian sum of bytes 0-17.
    static func setTime(_ date: Date = Date()) -> Data {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var b = [UInt8](command(0x1e, [UInt8((c.year ?? 2026) - 2000), UInt8(c.month ?? 1), UInt8(c.day ?? 1),
                                       UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0)]))
        let sum = b[0..<18].reduce(0) { $0 + Int($1) }
        b[18] = UInt8((sum >> 8) & 0xff); b[19] = UInt8(sum & 0xff)
        return Data(b)
    }
}

struct LiveSample: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let spo2: Int, hr: Int, worn: Bool, charging: Int, pi: Int
    var valid: Bool { spo2 > 0 || hr > 0 }
}

/// One stored per-second record from the ring (0x3c SECOND_DATA).
struct SecondRecord: Codable, Hashable {
    var t: Int32          // unix seconds (local wall time as recorded by the ring)
    var hr: UInt8
    var spo2: UInt8
    var motion: UInt8
    var x10: UInt8
    var signalS: Int16    // cleaned: raw u16 minus (record index & 255)
}

enum RingParser {
    static func date(_ b: ArraySlice<UInt8>) -> Date? {
        let a = Array(b); guard a.count >= 6 else { return nil }
        var c = DateComponents(); c.year = 2000 + Int(a[0]); c.month = Int(a[1]); c.day = Int(a[2])
        c.hour = Int(a[3]); c.minute = Int(a[4]); c.second = Int(a[5])
        return Calendar.current.date(from: c)
    }

    static func live(_ f: RingFrame, at d: Date = Date()) -> LiveSample? {
        guard f.cmd == 0x40, f.bytes.count >= 7 else { return nil }
        let b = f.bytes
        return LiveSample(date: d, spo2: Int(b[3]), hr: Int(b[4]), worn: b[5] > 0, charging: Int(b[6]), pi: b.count > 7 ? Int(b[7]) : 0)
    }

    static func secondRecord(_ f: RingFrame) -> SecondRecord? {
        let b = f.bytes
        guard f.cmd == 0x3c, b.count == 20, let d = date(b[2..<8]) else { return nil }
        let idx = (Int(b[14]) << 16) | (Int(b[15]) << 8) | Int(b[16])
        _ = idx
        let rawU16 = (Int(b[18]) << 8) | Int(b[19])
        let lowIndex = Int(b[16])
        return SecondRecord(t: Int32(d.timeIntervalSince1970), hr: b[8], spo2: b[9], motion: b[10], x10: b[12],
                            signalS: Int16(clamping: rawU16 - lowIndex))
    }

    static func ascii(_ f: RingFrame) -> String {
        String(bytes: f.bytes.dropFirst(3).filter { $0 >= 0x20 && $0 < 0x7f }, encoding: .ascii) ?? ""
    }
}
