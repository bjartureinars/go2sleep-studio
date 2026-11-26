import SwiftUI

@main
struct Go2SleepStudioApp: App {
    @State private var store = DataStore()
    @State private var ring = RingManager()

    var body: some Scene {
        WindowGroup("Go2Sleep Studio") {
            ContentView()
                .environment(store)
                .environment(ring)
                .frame(minWidth: 980, minHeight: 680)
                .onAppear {
                    ring.store = store
                    _ = Snapshot.runIfRequested(store: store, ring: ring)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in ring.flushLiveBackup(); ring.releaseLogger() }
        }
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarPanel().environment(ring).environment(store)
        } label: {
            if let s = ring.live, s.valid { Text("♥ \(s.hr)  \(s.spo2)%") } else { Image(systemName: "moon.zzz.fill") }
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandMenu("Ring") {
                Button("Connect") { ring.autoConnect = true; ring.connect() }.keyboardShortcut("k")
                Button("Sync History") { ring.syncHistory() }.keyboardShortcut("r").disabled(ring.state != .ready)
                Button("Start Live Measurement") { ring.startLive() }.keyboardShortcut("l").disabled(ring.state != .ready)
                Button("Sync Ring Clock") { ring.syncClock() }.disabled(ring.state != .ready)
                Divider()
                Button("Disconnect") { ring.disconnect() }
            }
        }
    }
}
