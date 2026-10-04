import XCTest
@testable import GrokDeskCore

final class ModelCatalogTests: XCTestCase {
    func testParsesStarAndDashes() {
        let stdout = """
        You are logged in with grok.com.

        Default model: grok-4.7

        Available models:
          * grok-4.7 (default)
          - grok-4.7-build-fast
          - grok-4.6
          - grok-4.5
        """
        let models = parseModels(stdout)
        XCTAssertEqual(models.map(\.id), ["grok-4.7", "grok-4.7-build-fast", "grok-4.6", "grok-4.5"])
        XCTAssertEqual(models.map(\.label), ["Grok 4.7", "Grok 4.7 Fast", "Grok 4.6", "Grok 4.5"])
        XCTAssertEqual(models.filter(\.isDefault).map(\.id), ["grok-4.7"])
    }

    func testFailureKeepsThePreviousListAndMarksItStale() {
        let prior = ModelCatalogState(
            models: [GrokModel(id: "grok-4.7", label: "Grok 4.7", isDefault: true)],
            stale: false
        )
        let next = reduceCatalog(prior, stdout: nil, failed: true)
        XCTAssertEqual(next.models.map(\.id), ["grok-4.7"])
        XCTAssertTrue(next.stale)
    }

    func testSuccessReplacesRatherThanAppends() {
        let prior = ModelCatalogState(
            models: [GrokModel(id: "grok-old", label: "Grok old", isDefault: true)],
            stale: true
        )
        let next = reduceCatalog(prior, stdout: "  - grok-4.7 (default)\n", failed: false)
        XCTAssertEqual(next.models.map(\.id), ["grok-4.7"])
        XCTAssertFalse(next.stale)
    }
}
