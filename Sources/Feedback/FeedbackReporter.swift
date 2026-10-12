import Foundation
import OSLog
import Sentry

/// Sentry: user feedback + crash reports, only when the build has a DSN
/// (`SENTRY_DSN` build setting → Info.plist `SentryDSN`). No tracing, no
/// screenshots, no default PII, never the text being read or API keys.
/// Offline sends are cached by the SDK and go out on the next launch.
enum FeedbackReporter {
    static let dsn: String? =
        (Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String).flatMap { $0.isEmpty ? nil : $0 }

    static var isConfigured: Bool { dsn != nil }
    static let notConfiguredMessage = "Feedback isn't set up in this build."

    static func start() {
        guard let dsn else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = "narrateify@\(Bundle.main.shortVersion)"
            options.dist = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            options.environment = "production"
            options.sendDefaultPii = false
            options.tracesSampleRate = nil
            options.enableAppHangTracking = false
            // No URLSession hooks: request bodies carry the text being read.
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            options.enableAutoPerformanceTracing = false
            options.debug = ProcessInfo.processInfo.environment["NARRATEIFY_SENTRY_DEBUG"] == "1"
        }
    }

    enum Result: Equatable {
        case notConfigured
        case sent
    }

    /// Sends the message with the app's recent log lines attached. Reading the
    /// log store and flushing block for a second or more, so that runs on a
    /// GCD queue rather than tying up a Swift concurrency thread.
    static func send(message: String, tags: [String: String], context: [String: Any]) async -> Result {
        guard isConfigured else { return .notConfigured }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        nonisolated(unsafe) let context = context   // plain values only
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let log = Attachment(data: Data(recentLog().utf8), filename: "recent-log.txt", contentType: "text/plain")
                // Scope is global: set for this capture only, so later crash
                // reports don't carry a stale snapshot.
                SentrySDK.configureScope { scope in
                    for (key, value) in tags { scope.setTag(value: value, key: key) }
                    scope.setContext(value: context, key: "narrateify")
                }
                SentrySDK.capture(feedback: SentryFeedback(
                    message: message,
                    name: Host.current().localizedName,
                    email: nil,
                    source: .custom,
                    attachments: [log]
                ))
                SentrySDK.configureScope { scope in
                    for key in tags.keys { scope.removeTag(key: key) }
                    scope.removeContext(key: "narrateify")
                }
                SentrySDK.flush(timeout: 5)
                done.resume()
            }
        }
        return .sent
    }

    /// This process's last `limit` log lines. Our `Logger` calls only log
    /// engines, voices, counts, timings and errors, never the text being read.
    /// (The store ignores `.reverse` here, so it's a forward scan, kept bounded.)
    static func recentLog(limit: Int = 300) -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(matching: NSPredicate(format: "subsystem == %@", Logger.subsystem))
        else { return "(log unavailable)" }
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            lines.append("\(entry.date.ISO8601Format()) [\(entry.category)] \(entry.composedMessage)")
            if lines.count > limit * 2 { lines.removeFirst(limit) }
        }
        return lines.suffix(limit).joined(separator: "\n")
    }
}
