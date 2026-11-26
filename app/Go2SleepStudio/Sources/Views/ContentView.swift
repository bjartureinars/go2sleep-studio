import SwiftUI

enum Route: Hashable { case live, night(Date), trends, device, lab }

struct ContentView: View {
    @Environment(DataStore.self) private var store
    @Environment(RingManager.self) private var ring
    @State private var route: Route? = nil

    var body: some View {
        NavigationSplitView {
            List(selection: $route) {
                Section {
                    Label("Live", systemImage: "waveform.path.ecg").tag(Route.live)
                    if let last = store.nights.first {
                        Label("Last Night", systemImage: "moon.stars.fill").tag(Route.night(last.start))
                    }
                    Label("Trends", systemImage: "chart.xyaxis.line").tag(Route.trends)
                }
                Section("Nights") {
                    ForEach(store.nights) { n in
                        NightRow(night: n).tag(Route.night(n.start))
                    }
                }
                Section("Ring") {
                    Label("Device", systemImage: "circle.circle").tag(Route.device)
                    Label("Lab", systemImage: "terminal").tag(Route.lab)
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
            .safeAreaInset(edge: .bottom) { ConnectionBadge().padding(10) }
        } detail: {
            switch route {
            case .live, .none: LiveView()
            case .night(let d): if let n = store.nights.first(where: { $0.start == d }) { NightView(night: n) } else { ContentUnavailableView("Night not found", systemImage: "moon") }
            case .trends: TrendsView()
            case .device: DeviceView()
            case .lab: LabView()
            }
        }
        .onAppear { if route == nil { route = store.nights.first.map { .night($0.start) } ?? .live } }
    }
}

struct NightRow: View {
    let night: Night
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Palette.score(night.score.total).opacity(0.2))
                Text("\(night.score.total)").font(.system(.callout, design: .rounded).weight(.bold)).monospacedDigit().foregroundStyle(Palette.score(night.score.total))
            }.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(night.nightOf, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated)).font(.body.weight(.medium))
                HypnogramChart(epochs: night.epochs, compact: true).frame(height: 16)
                Text(night.metrics.tstMin.hm + " asleep").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct ConnectionBadge: View {
    @Environment(RingManager.self) private var ring
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(ring.state == .ready || ring.state == .syncing ? Color.green : (ring.state == .idle ? Color.gray : Color.orange)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(ring.deviceName ?? "Go2Sleep ring").font(.caption.weight(.semibold))
                Text(ring.statusText + (ring.battery.map { " · \($0)%" } ?? "")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
