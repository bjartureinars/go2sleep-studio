import SwiftUI
import UniformTypeIdentifiers

struct DeviceView: View {
    @Environment(RingManager.self) private var ring
    @Environment(DataStore.self) private var store
    @State private var importing = false

    var body: some View {
        @Bindable var ring = ring
        Form {
            Section("Ring") {
                LabeledContent("Status", value: ring.statusText)
                LabeledContent("Name", value: ring.deviceName ?? "–")
                LabeledContent("Serial", value: ring.serial ?? "–")
                LabeledContent("Firmware", value: ring.firmware ?? "–")
                LabeledContent("Battery", value: ring.battery.map { "\($0)%" } ?? "–")
                LabeledContent("Signal", value: ring.rssi.map { "\($0) dBm" } ?? "–")
                LabeledContent("Ring clock") {
                    if let c = ring.ringClock {
                        Text(c.formatted(date: .abbreviated, time: .standard) + (ring.clockDriftSec.map { String(format: "  (%+.0f s)", $0) } ?? ""))
                    } else { Text("–") }
                }
                HStack {
                    Button("Connect") { ring.autoConnect = true; ring.connect() }.disabled(ring.state == .ready || ring.state == .syncing)
                    Button("Sync Clock") { ring.syncClock() }.disabled(ring.state != .ready)
                    Button("Sync History") { ring.syncHistory() }.disabled(ring.state != .ready)
                    Button("Disconnect") { ring.disconnect() }
                }
                Toggle("Connect automatically", isOn: $ring.autoConnect)
                Toggle("Keep the ring's clock in sync", isOn: $ring.autoSetClock)
                Toggle("Keep the Mac awake while connected (needed for overnight live data)", isOn: $ring.keepAwake)
            }
            Section("Automatic monitoring") {
                Text("The ring starts measuring by itself when worn (it vibrates twice and lights up). If its battery runs flat it can lose this setting; restore it here.").font(.callout).foregroundStyle(.secondary)
                Picker("Trigger sensitivity", selection: Binding(get: { ring.sensitivity }, set: { ring.setSensitivity($0) })) {
                    Text("1 · Weakest").tag(1); Text("2 · Default").tag(2); Text("3").tag(3); Text("4").tag(4); Text("5 · Most sensitive").tag(5)
                }.disabled(ring.state != .ready)
                HStack {
                    Button("Restore Automatic Monitoring") { ring.restoreAutoMonitoring() }.disabled(ring.state != .ready)
                    if let d = ring.sensitivityAck { Label("Ring confirmed at \(d.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
                }
            }
            Section("Data") {
                LabeledContent("Stored", value: store.statusMessage)
                LabeledContent("Last history sync", value: ring.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "–")
                HStack {
                    Button("Import CSV…") { importing = true }
                    Button("Export CSV…") { export() }
                    Button("Show Data Folder") { NSWorkspace.shared.activateFileViewerSelecting([store.folder]) }
                    Button("Re-analyse") { store.reanalyse() }
                }
            }
            Section("About") {
                Text("Go2Sleep Studio talks to the ring directly over Bluetooth (Nordic UART). It never sends commands that erase, reset or vibrate the ring.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Device")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { r in
            if case .success(let url) = r { _ = url.startAccessingSecurityScopedResource(); store.importCSV(url); url.stopAccessingSecurityScopedResource() }
        }
    }

    private func export() {
        let p = NSSavePanel(); p.nameFieldStringValue = "go2sleep-history.csv"; p.allowedContentTypes = [.commaSeparatedText]
        if p.runModal() == .OK, let u = p.url { try? store.exportCSV(to: u) }
    }
}
