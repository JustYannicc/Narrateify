import Foundation

/// Where the local API lives. Compiled into both the app and the `narrateify` CLI.
enum APIEndpoint {
    static let preferredPort: UInt16 = 47801
    static let appBundleID = "com.narrateify.Narrateify"

    /// Written by the app once it's listening: {port, url, pid, version}.
    static var discoveryFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Narrateify/api.json")
    }
}
