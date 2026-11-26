import Foundation

/// Writes a rolling event log (ring.log) and a live status snapshot (status.json) to Application Support,
/// so connection problems can be diagnosed without looking at the UI.
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()
    private let queue = DispatchQueue(label: "diagnostics")
    let folder: URL
    private var handle: FileHandle?
    private let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()

    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Go2SleepStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("ring.log")
        if let a = try? FileManager.default.attributesOfItem(atPath: url.path), (a[.size] as? Int ?? 0) > 20_000_000 {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("ring.old.log"))
            try? FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("ring.old.log"))
        }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url); handle?.seekToEndOfFile()
    }

    func write(_ line: String) {
        let s = "\(fmt.string(from: Date())) \(line)\n"
        queue.async { self.handle?.write(Data(s.utf8)) }
    }

    func status(_ d: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = folder.appendingPathComponent("status.json")
        queue.async { try? data.write(to: url, options: .atomic) }
    }
}
