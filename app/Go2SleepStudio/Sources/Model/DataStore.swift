import Foundation
import Observation

/// Persists per-second ring records (deduplicated by timestamp) and caches the analysed nights.
@MainActor @Observable
final class DataStore {
    private(set) var records: [SecondRecord] = []
    private(set) var nights: [Night] = []
    private(set) var lastSaved: Date?
    var statusMessage: String = ""

    let folder: URL
    private var fileURL: URL { folder.appendingPathComponent("records.bin") }

    /// Project CSV produced by the Python tools; imported automatically on first launch.
    static let projectCSV = URL(fileURLWithPath: "/Users/bjartur/sleepon go2sleep/data/history_seconds.csv")

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("Go2SleepStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
        if records.isEmpty, FileManager.default.fileExists(atPath: Self.projectCSV.path) {
            importCSV(Self.projectCSV)
        }
    }

    // MARK: merge + persistence
    /// Merges records by timestamp. `overwrite: false` only fills gaps (used for live backup, so the ring's own
    /// stored history always wins when it is synced later).
    func merge(_ new: [SecondRecord], overwrite: Bool = true) {
        guard !new.isEmpty else { return }
        var byTime = Dictionary(uniqueKeysWithValues: records.map { ($0.t, $0) })
        for r in new where overwrite || byTime[r.t] == nil { byTime[r.t] = r }
        records = byTime.values.sorted { $0.t < $1.t }
        save()
        reanalyse()
    }

    func reanalyse() {
        nights = SleepEngine.analyse(records: records)
        statusMessage = "\(records.count.formatted()) seconds · \(nights.count) nights"
    }

    func save() {
        var d = Data(capacity: records.count * 10)
        for r in records {
            var t = r.t.littleEndian; withUnsafeBytes(of: &t) { d.append(contentsOf: $0) }
            d.append(contentsOf: [r.hr, r.spo2, r.motion, r.x10])
            var s = r.signalS.littleEndian; withUnsafeBytes(of: &s) { d.append(contentsOf: $0) }
        }
        try? d.write(to: fileURL, options: .atomic)
        lastSaved = Date()
    }

    func load() {
        guard let d = try? Data(contentsOf: fileURL) else { return }
        var out: [SecondRecord] = []; out.reserveCapacity(d.count / 10)
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var i = 0
            while i + 10 <= p.count {
                let t = Int32(littleEndian: p.loadUnaligned(fromByteOffset: i, as: Int32.self))
                let s = Int16(littleEndian: p.loadUnaligned(fromByteOffset: i + 8, as: Int16.self))
                out.append(SecondRecord(t: t, hr: p[i + 4], spo2: p[i + 5], motion: p[i + 6], x10: p[i + 7], signalS: s))
                i += 10
            }
        }
        records = out
        reanalyse()
    }

    /// Imports `history_seconds.csv` (time,hr,spo2,motion,x10,record_index,slow_raw,signal_s) off the main thread.
    func importCSV(_ url: URL) {
        statusMessage = "Importing \(url.lastPathComponent)…"
        Task.detached(priority: .userInitiated) {
            let rows = Self.parseCSV(url)
            await MainActor.run {
                self.merge(rows)
                self.statusMessage = rows.isEmpty ? "No rows found in \(url.lastPathComponent)" : "Imported \(rows.count.formatted()) seconds · \(self.nights.count) nights"
            }
        }
    }

    nonisolated static func parseCSV(_ url: URL) -> [SecondRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var rows: [SecondRecord] = []; var header: [String] = []
        let tz = TimeZone.current
        for (n, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            let c = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if n == 0 { header = c; continue }
            guard c.count >= 5, let utc = fastEpoch(c[0]) else { continue }
            func v(_ k: String) -> Int { header.firstIndex(of: k).flatMap { $0 < c.count ? Int(c[$0]) : nil } ?? 0 }
            let local = utc - tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(utc)))
            let s = header.contains("signal_s") ? v("signal_s") : v("slow_signal")
            rows.append(SecondRecord(t: Int32(local), hr: UInt8(clamping: v("hr")), spo2: UInt8(clamping: v("spo2")),
                                     motion: UInt8(clamping: v("motion")), x10: UInt8(clamping: v("x10")), signalS: Int16(clamping: s)))
        }
        return rows
    }

    /// "yyyy-MM-dd HH:mm:ss" -> seconds since 1970 treating the fields as UTC (days-from-civil algorithm).
    nonisolated static func fastEpoch(_ s: String) -> Int? {
        let u = Array(s.utf8); guard u.count >= 19 else { return nil }
        func num(_ a: Int, _ b: Int) -> Int { var v = 0; for i in a..<b { v = v * 10 + Int(u[i] &- 48) }; return v }
        var y = num(0, 4); let m = num(5, 7), d = num(8, 10), h = num(11, 13), mi = num(14, 16), se = num(17, 19)
        y -= m <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400, yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1, doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return days * 86400 + h * 3600 + mi * 60 + se
    }

    func exportCSV(to url: URL) throws {
        var s = "time,hr,spo2,motion,x10,signal_s\n"
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for r in records {
            s += "\(fmt.string(from: Date(timeIntervalSince1970: TimeInterval(r.t)))),\(r.hr),\(r.spo2),\(r.motion),\(r.x10),\(r.signalS)\n"
        }
        try s.write(to: url, atomically: true, encoding: .utf8)
    }
}
