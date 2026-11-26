import SwiftUI
import Charts

struct LiveView: View {
    @Environment(RingManager.self) private var ring
    var scrolls = true

    var body: some View {
        let s = ring.live
        let valid = ring.liveHistory.filter { $0.valid }
        MaybeScroll(on: scrolls) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Live").font(.largeTitle.bold())
                        Text(ring.statusText + (ring.deviceName.map { " · \($0)" } ?? "")).foregroundStyle(.secondary)
                    }
                    Spacer()
                    controls
                }
                if let b = ring.battery, b < 40, ring.state == .ready || ring.state == .syncing {
                    Label(b < 20 ? "Ring battery is \(b)%. Charge it now: if it runs flat the ring forgets its settings and stops recording." : "Ring battery is \(b)%. Charge it before going to sleep so it lasts the night.", systemImage: b < 20 ? "battery.0percent" : "battery.25percent")
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background((b < 20 ? Color.red : Color.orange).opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                }
                if let h = ring.autoHealed {
                    Label("The ring had lost power and reset at some point. Automatic monitoring was restored at \(h.formatted(date: .omitted, time: .shortened)).", systemImage: "wand.and.stars")
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                if ring.state == .syncing {
                    Card(title: "Syncing stored history", symbol: "arrow.down.circle.fill", tint: Palette.oxygen) {
                        ProgressView().progressViewStyle(.linear)
                        Text("\(ring.syncCount.formatted()) seconds received" + (ring.syncLastDate.map { " · up to \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")).font(.callout).monospacedDigit()
                    }
                }
                if ring.state == .ready, let s, !s.valid {
                    Label("The ring is connected but isn't measuring right now. Wear it snugly; live values appear when the ring's sensor is running.", systemImage: "hand.point.up.left.fill")
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    MetricTile(title: "SpO₂", value: s.map { $0.spo2 > 0 ? "\($0.spo2)" : "–" } ?? "–", unit: "%", symbol: "lungs.fill", tint: Palette.oxygen)
                    MetricTile(title: "Heart rate", value: s.map { $0.hr > 0 ? "\($0.hr)" : "–" } ?? "–", unit: "bpm", symbol: "heart.fill", tint: Palette.heart)
                    MetricTile(title: "Perfusion", value: s.map { $0.worn && $0.pi > 0 ? String(format: "%.1f", Double($0.pi) / 10) : "–" } ?? "–", unit: "PI", symbol: "drop.fill", tint: Palette.perfusion, footnote: "pulse strength at the finger")
                    MetricTile(title: "On finger", value: s.map { $0.worn ? "Yes" : "No" } ?? "–", symbol: "hand.raised.fill", tint: .purple)
                    MetricTile(title: "Battery", value: ring.battery.map { "\($0)" } ?? "–", unit: "%", symbol: "battery.75percent", tint: Palette.battery)
                    MetricTile(title: "Signal", value: ring.rssi.map { "\($0)" } ?? "–", unit: "dBm", symbol: "antenna.radiowaves.left.and.right", tint: .teal)
                }
                if !ring.pulse.isEmpty {
                    Card(title: "Pulse waveform", symbol: "waveform", tint: Palette.perfusion) {
                        Chart(Array(ring.pulse.suffix(300).enumerated()), id: \.offset) { p in
                            LineMark(x: .value("Sample", p.offset), y: .value("Amplitude", p.element)).foregroundStyle(Palette.perfusion).interpolationMethod(.catmullRom)
                        }
                        .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 90)
                    }
                }
                Card(title: "Last 30 minutes", symbol: "waveform.path.ecg", tint: Palette.heart) {
                    if valid.isEmpty {
                        Text("No valid live readings yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        Chart(valid) { p in
                            LineMark(x: .value("Time", p.date), y: .value("Value", p.hr), series: .value("Signal", "Heart rate")).foregroundStyle(Palette.heart)
                            LineMark(x: .value("Time", p.date), y: .value("Value", p.spo2), series: .value("Signal", "SpO₂")).foregroundStyle(Palette.oxygen)
                        }
                        .chartForegroundStyleScale(["Heart rate": Palette.heart, "SpO₂": Palette.oxygen])
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 220)
                    }
                }
                Card(title: "How live mode works", symbol: "info.circle", tint: .secondary) {
                    Text("The ring measures on its own whenever it detects a finger: it vibrates twice, lights up and streams SpO₂ and heart rate once a second. Values appear a few seconds after the ring detects a finger. While connected, the app keeps the Mac awake, saves the live readings as a backup, and downloads the ring's full recording once the ring has been off your finger for 10 minutes. The ring only accepts one connection.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let a = ring.airplaneMode { Label(a ? "Airplane mode is ON in the ring: live data is disabled" : "Ring airplane mode: off", systemImage: a ? "airplane" : "checkmark.circle").font(.callout).foregroundStyle(a ? .orange : .secondary) }
                    if let m = ring.ringMode { Label("Ring mode reported: \(m == 1 ? "ring" : (m == 2 ? "fingertip" : "\(m)"))", systemImage: "circle.circle").font(.callout).foregroundStyle(.secondary) }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder private var controls: some View {
        HStack {
            switch ring.state {
            case .idle, .bluetoothOff, .unauthorized:
                Button { ring.autoConnect = true; ring.connect() } label: { Label("Connect", systemImage: "link") }.buttonStyle(.borderedProminent)
            case .scanning, .connecting, .waking:
                ProgressView().controlSize(.small)
                Button("Cancel") { ring.disconnect() }
            case .ready, .syncing:
                Button { ring.startLive() } label: { Label("Measure", systemImage: "play.circle") }
                Button { ring.syncHistory() } label: { Label("Sync Night", systemImage: "arrow.down.circle") }.buttonStyle(.borderedProminent).disabled(ring.state == .syncing)
                Button { ring.disconnect() } label: { Label("Disconnect", systemImage: "xmark.circle") }
            }
        }
    }
}
