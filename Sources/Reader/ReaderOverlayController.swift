import SwiftUI
import AppKit

/// Shows a `ReadingSession` in a floating, draggable, non-activating panel —
/// same plumbing as `SynthesisOverlay`, separate saved position.
///
/// The transport methods here are what global hotkeys should call: the panel
/// is non-activating, so its own key handling (←/→, space, esc, ↑/↓) only
/// works once the user has clicked into it.
@MainActor
final class ReaderOverlayController: NSObject, NSWindowDelegate {
    static let shared = ReaderOverlayController()

    /// Called after the user closes the reader (button or esc). The session is
    /// already stopped by then.
    var onClose: (() -> Void)?

    private(set) var session: ReadingSession?
    private var panel: ReaderPanel?

    private let originXKey = "readerOverlayOriginX"
    private let originYKey = "readerOverlayOriginY"

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Show `session` (replacing any previous one's view). Doesn't start it.
    func show(_ session: ReadingSession) {
        self.session = session
        let panel = ensurePanel()
        panel.contentView = makeHostingView(for: session)
        guard !panel.isVisible else {
            position(panel, keepOrigin: true)
            return
        }

        position(panel)
        let target = panel.frame
        var start = target
        start.origin.y -= 16
        panel.alphaValue = 0
        panel.setFrame(start, display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    /// Forget the saved position and recenter (for Settings).
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: originXKey)
        UserDefaults.standard.removeObject(forKey: originYKey)
        if let panel, panel.isVisible { position(panel, ignoringSaved: true) }
    }

    // MARK: Transport (bind global hotkeys here)

    func togglePlayPause() { session?.togglePlayPause() }
    func next() { session?.next() }
    func previous() { session?.previous() }
    func faster() { session?.faster() }
    func slower() { session?.slower() }

    /// Stop reading and dismiss.
    func close() {
        session?.stop()
        hide()
        onClose?()
    }

    // MARK: Panel plumbing

    private func makeHostingView(for session: ReadingSession) -> NSView {
        let hosting = NSHostingView(rootView: ReaderOverlayView(session: session) { [weak self] in
            self?.close()
        })
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        return hosting
    }

    private func ensurePanel() -> ReaderPanel {
        if let panel { return panel }
        let panel = ReaderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false                  // SwiftUI draws the shadow
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.onKey = { [weak self] key in self?.handle(key) ?? false }
        self.panel = panel
        return panel
    }

    private func handle(_ key: ReaderPanel.Key) -> Bool {
        guard session != nil else { return false }
        switch key {
        case .previous:  previous()
        case .next:      next()
        case .playPause: togglePlayPause()
        case .faster:    faster()
        case .slower:    slower()
        case .close:     close()
        }
        return true
    }

    /// Size to fit; place at the saved origin, or bottom-center by default.
    private func position(_ panel: ReaderPanel, ignoringSaved: Bool = false, keepOrigin: Bool = false) {
        guard let content = panel.contentView else { return }
        let size = content.fittingSize
        if keepOrigin {
            // Grow/shrink around the top edge so the box doesn't jump.
            let top = panel.frame.maxY
            panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height,
                                  width: size.width, height: size.height), display: true)
            return
        }
        panel.setContentSize(size)

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vis = screen.visibleFrame
        let defaults = UserDefaults.standard
        if !ignoringSaved,
           defaults.object(forKey: originXKey) != nil,
           defaults.object(forKey: originYKey) != nil {
            let x = min(max(defaults.double(forKey: originXKey), vis.minX), vis.maxX - size.width)
            let y = min(max(defaults.double(forKey: originYKey), vis.minY), vis.maxY - size.height)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.setFrameOrigin(NSPoint(x: vis.midX - size.width / 2, y: vis.minY + 120))
        }
    }

    // MARK: NSWindowDelegate — persist the dragged position

    func windowDidMove(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        UserDefaults.standard.set(panel.frame.origin.x, forKey: originXKey)
        UserDefaults.standard.set(panel.frame.origin.y, forKey: originYKey)
    }
}

/// Borderless panel that can become key (so its controls and keys work)
/// without activating the app. Intercepts the reader's shortcut keys.
final class ReaderPanel: NSPanel {
    enum Key { case previous, next, playPause, faster, slower, close }

    var onKey: ((Key) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let key = Self.key(for: event.keyCode),
           onKey?(key) == true {
            return
        }
        super.sendEvent(event)
    }

    private static func key(for code: UInt16) -> Key? {
        switch code {
        case 123: return .previous    // ←
        case 124: return .next        // →
        case 49:  return .playPause   // space
        case 126: return .faster      // ↑
        case 125: return .slower      // ↓
        case 53:  return .close       // esc
        default:  return nil
        }
    }
}
