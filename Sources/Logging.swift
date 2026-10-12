import OSLog

extension Logger {
    /// Every app logger uses this subsystem; Send Feedback attaches its lines.
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.narrateify.Narrateify"

    init(category: String) { self.init(subsystem: Self.subsystem, category: category) }
}

extension Bundle {
    /// Marketing version, e.g. "2.0.0".
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}
