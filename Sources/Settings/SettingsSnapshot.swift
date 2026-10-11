#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: `-snapshotSettings /some/dir` renders each Settings tab
/// offscreen to PNGs (no Screen Recording permission needed) so UI changes can
/// be checked from the command line.
enum SettingsSnapshot {
    @MainActor
    static func runIfRequested(state: AppState) {
        guard let dir = UserDefaults.standard.string(forKey: "snapshotSettings") else { return }
        let tabs: [(String, AnyView)] = [
            ("reading", AnyView(ReadingSettingsView(settings: state.narrator.settings))),
            ("engines", AnyView(EnginesView())),
            ("cloud", AnyView(CloudView())),
            ("general", AnyView(GeneralView())),
        ]
        for (name, view) in tabs {
            render(view.environmentObject(state), size: NSSize(width: 620, height: 1400),
                   to: URL(fileURLWithPath: dir).appendingPathComponent("settings-\(name).png"))
        }
    }

    @MainActor
    private static func render(_ view: some View, size: NSSize, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        // Let async .task work (voice lists) land before capturing.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
