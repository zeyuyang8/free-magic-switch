import SwiftUI

@main
struct DeviceHopApp: App {
    @StateObject private var model = AppModel()

    init() {
        if let path = ProcessInfo.processInfo.environment["DEVICEHOP_SNAPSHOT"] {
            Snapshot.render(to: path)
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            Image(systemName: model.busy || model.updating ? "arrow.left.arrow.right" : "keyboard")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Dev aid: DEVICEHOP_SNAPSHOT=out.png [DEVICEHOP_DARK=1] [DEVICEHOP_REAL_DEVICES=1] renders the panel.
enum Snapshot {
    static func render(to path: String) {
        _ = NSApplication.shared
        let env = ProcessInfo.processInfo.environment
        let dark = env["DEVICEHOP_DARK"] != nil
        let model = AppModel(preview: true)
        if env["DEVICEHOP_REAL_DEVICES"] != nil { model.devices = Bluetooth().pairedDevices() }
        let view = ContentView(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
