import AppKit

/// What a feedback report carries besides your message. Settings and state
/// only: never the text being read, history, or API keys (just whether one is
/// set). OS, arch and app version come with every Sentry event already.
extension AppState {
    var feedbackTags: [String: String] {
        [
            "accessibility": String(AXIsProcessTrusted()),
            "reading": String(isReading),
            "overlay": String(overlayEnabled),
            "supertonic_backend": "\(SupertonicBackend.current)",
        ]
    }

    func sendFeedback(_ message: String) async -> FeedbackReporter.Result {
        await FeedbackReporter.send(message: message, tags: feedbackTags, context: feedbackContext)
    }

    var feedbackContext: [String: Any] {
        let settings = narrator.settings
        return [
            "status": status,
            "speed": audio.rate,
            "languages": settings.profiles.map { profile in
                [
                    "language": profile.language.code,
                    "routes": profile.routes.map(\.id),
                ] as [String: Any]
            },
            "benched": SpeechEngineKind.allCases.filter(narrator.isBenched).map(\.rawValue),
            "supertonic": [
                "install": "\(supertonic.state)",
                "loaded": supertonicEngine.loadedBackend.map { "\($0)" } ?? "no",
                "keep_warm": settings.keepModelsWarm,
                "unload_after_min": settings.unloadAfterMinutes,
            ] as [String: Any],
            "keys_set": [
                "elevenlabs": !apiKey.isEmpty,
                "openai": !openAIKey.isEmpty,
            ],
            "text": [
                "clean": cleanText,
                "citations": citationMode.rawValue,
                "pronunciation_rules": pronunciations.count,
                "translate": translateEnabled ? translateLanguage.rawValue : "off",
                "clipboard_watch": clipboardWatch,
            ] as [String: Any],
            "queue": queue.count,
        ]
    }
}
