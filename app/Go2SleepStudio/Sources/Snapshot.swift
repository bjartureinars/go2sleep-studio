import SwiftUI

/// `Go2SleepStudio --snapshot <dir>` renders the main screens to PNG and writes night metrics as JSON, then quits.
/// Used for headless verification.
@MainActor enum Snapshot {
    static func runIfRequested(store: DataStore, ring: RingManager) -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return false }
        Task { @MainActor in
            for _ in 0..<120 where store.nights.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
            write(store: store, ring: ring, dir: URL(fileURLWithPath: args[i + 1]))
            NSApp.terminate(nil)
        }
        return true
    }

    static func write(store: DataStore, ring: RingManager, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func render<V: View>(_ v: V, _ name: String, _ size: CGSize, dark: Bool) {
            let view = v.environment(store).environment(ring).frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: view); r.scale = 1
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(name + ".png"))
            }
        }
        if let n = store.nights.first {
            render(NightView(night: n, scrolls: false), "night_dark", CGSize(width: 1100, height: 1900), dark: true)
            NightView.writePDF(night: n, to: dir.appendingPathComponent("report.pdf"))
            render(NightView(night: n, scrolls: false), "night_light", CGSize(width: 1100, height: 1900), dark: false)
        }
        render(TrendsView(scrolls: false), "trends_dark", CGSize(width: 1100, height: 1500), dark: true)
        render(LiveView(scrolls: false), "live_dark", CGSize(width: 1100, height: 800), dark: true)
        var rows: [[String: Any]] = []
        for n in store.nights {
            let m = n.metrics
            rows.append(["start": n.start.description, "score": n.score.total, "tst_min": Int(m.tstMin), "eff": Int(m.efficiency), "latency": Int(m.latencyMin),
                         "waso": Int(m.wasoMin), "light": Int(m.pct(.light)), "deep": Int(m.pct(.deep)), "rem": Int(m.pct(.rem)),
                         "rem_latency": Int(m.remLatencyMin ?? -1), "resting_hr": Int(m.restingHR), "spo2_min": m.spo2Min, "odi3": (m.odi3 * 10).rounded() / 10,
                         "t90": m.t90Sec, "moves_h": (m.movementsPerHour * 10).rounded() / 10, "bad_pct": Int(m.badSignalPct)])
        }
        if let d = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) { try? d.write(to: dir.appendingPathComponent("nights.json")) }
    }
}
