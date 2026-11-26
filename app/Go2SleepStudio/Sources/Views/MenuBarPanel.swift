import SwiftUI

/// Small window shown from the menu bar: connection, live vitals and last night's score.
struct MenuBarPanel: View {
    @Environment(RingManager.self) private var ring
    @Environment(DataStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Go2Sleep").font(.headline)
                Spacer()
                Text(ring.statusText + (ring.battery.map { " · \($0)%" } ?? "")).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                let s = ring.live
                MetricTile(title: "SpO₂", value: s.map { $0.spo2 > 0 ? "\($0.spo2)" : "–" } ?? "–", unit: "%", symbol: "lungs.fill", tint: Palette.oxygen)
                MetricTile(title: "Heart", value: s.map { $0.hr > 0 ? "\($0.hr)" : "–" } ?? "–", unit: "bpm", symbol: "heart.fill", tint: Palette.heart)
            }
            if let n = store.nights.first {
                HStack(spacing: 12) {
                    ScoreRing(score: n.score.total, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Night of " + n.nightOf.formatted(.dateTime.weekday(.wide).day().month())).font(.callout.weight(.medium))
                        Text(n.metrics.tstMin.hm + " asleep · deep \(Int(n.metrics.pct(.deep)))% · REM \(Int(n.metrics.pct(.rem)))%").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                if ring.state == .ready { Button("Sync Night") { ring.syncHistory() } } else { Button("Connect") { ring.autoConnect = true; ring.connect() } }
                Spacer()
                Button("Open App") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
