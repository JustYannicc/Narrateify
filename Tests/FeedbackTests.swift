import XCTest
import OSLog
@testable import Narrateify

final class FeedbackTests: XCTestCase {
    /// The report's log attachment is read back from this process's log store.
    func testRecentLogHasThisProcessesLines() {
        let marker = UUID().uuidString
        Logger(category: "test")
            .notice("feedback marker \(marker, privacy: .public)")
        XCTAssertTrue(FeedbackReporter.recentLog().contains("[test] feedback marker \(marker)"))
    }

    @MainActor
    func testContextCarriesNoKeys() {
        let state = AppState.shared
        let context = state.feedbackContext
        let dump = "\(context)"
        if !state.apiKey.isEmpty { XCTAssertFalse(dump.contains(state.apiKey)) }
        if !state.openAIKey.isEmpty { XCTAssertFalse(dump.contains(state.openAIKey)) }
        XCTAssertNotNil(context["languages"])
    }
}
