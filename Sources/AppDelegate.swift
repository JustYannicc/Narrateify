import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let serviceProvider = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When the app is launched as the unit-test host, skip all the live
        // setup (hotkeys, onboarding, network checks) — tests only need the types.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        // Run as a background "agent" — no Dock icon, no app menu.
        // (Setting LSUIElement = YES in Info.plist does the same at launch;
        //  this is a belt-and-suspenders fallback.)
        NSApp.setActivationPolicy(.accessory)

        // Make the "Narrate with Narrateify" Service available in the
        // right-click → Services menu of other apps.
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()

        registerHotKeys()

        // First launch: show the onboarding wizard (which handles the permission
        // prompts). On later launches, just re-assert the Accessibility prompt.
        if UserDefaults.standard.bool(forKey: OnboardingWindow.didOnboardKey) {
            promptForAccessibilityIfNeeded()
        } else {
            Task { @MainActor in OnboardingWindow.showIfNeeded() }
        }

        // Warm the engines (Edge voice list, Supertonic model if kept loaded)
        // so the first shortcut press reads immediately.
        Task { @MainActor in AppState.shared.warmUpEngines() }

        #if DEBUG
        // `-narrateText "…"` reads text on launch — lets the full pipeline be
        // exercised without Accessibility permission or a hotkey.
        if let text = UserDefaults.standard.string(forKey: "narrateText"), !text.isEmpty {
            // `-narrateDelay 5` waits first, to measure warm (post-preload) latency.
            let delay = UserDefaults.standard.double(forKey: "narrateDelay")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                AppState.shared.narrate(text)
            }
        }
        Task { @MainActor in SettingsSnapshot.runIfRequested(state: AppState.shared) }
        #endif

        // Quietly check GitHub for a newer release in the background.
        Task { @MainActor in await AppState.shared.updateChecker.check() }
    }

    private func registerHotKeys() {
        // Bindings are user-editable (Settings → General → Shortcuts) and
        // persisted; the store registers them all with HotKeyManager.
        MainActor.assumeIsolated { AppState.shared.shortcutStore.applyAll() }
    }

    /// Triggers the system prompt to grant Accessibility access (needed to read
    /// selected text by synthesizing ⌘C). Safe to call every launch.
    private func promptForAccessibilityIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
