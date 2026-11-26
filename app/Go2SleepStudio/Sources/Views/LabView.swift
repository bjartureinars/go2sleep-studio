import SwiftUI

/// Developer console: send raw commands and watch every frame.
struct LabView: View {
    @Environment(RingManager.self) private var ring
    @State private var hex = "5a 14 00"

    private let quick: [(String, String)] = [("Firmware", "5a 14 00"), ("Battery", "5a 15 00 00"), ("Serial", "5a 03 00"), ("Clock", "5a 1d 00"),
                                             ("Sensor reg", "5a 29 00"), ("Monitoring on", "5a 30 00 01"), ("Pulse on", "5a 41 00 01"), ("Pulse off", "5a 41 00 00")]

    var body: some View {
        @Bindable var ring = ring
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Hex command", text: $hex).font(.body.monospaced()).textFieldStyle(.roundedBorder).onSubmit { ring.sendHex(hex) }
                Button("Send") { ring.sendHex(hex) }.keyboardShortcut(.return).disabled(ring.state != .ready)
            }
            ScrollView(.horizontal) { HStack { ForEach(quick, id: \.0) { q in Button(q.0) { hex = q.1; ring.sendHex(q.1) }.disabled(ring.state != .ready) } } }
            HStack {
                Text("Live-start command:"); TextField("", text: $ring.liveStartHex).font(.body.monospaced()).frame(width: 200)
                Text("Blocked: erase, reset, restart, vibrate, light, write-serial, BLE-type, 0x12, 0x54; 0x30 only on, 0x50 only 1–5.").font(.caption).foregroundStyle(.secondary)
            }
            List(Array(ring.rawLog.suffix(600).enumerated().reversed()), id: \.offset) { _, e in
                HStack(alignment: .firstTextBaseline) {
                    Text(e.date, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    Text(e.dir).foregroundStyle(e.dir == "→" ? .blue : (e.dir == "!!" ? .orange : .green)).frame(width: 20)
                    Text(e.hex).textSelection(.enabled)
                }.font(.caption.monospaced())
            }
        }
        .padding(16)
        .navigationTitle("Lab")
    }
}
