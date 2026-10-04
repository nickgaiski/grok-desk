import XCTest
@testable import GrokDeskCore

final class SubscriptionTests: XCTestCase {
    func testReadsPercentLeftFromTheLatestCreditLine() {
        let older = #"{"ctx":{"config":{"creditUsagePercent":80},"subscriptionTier":"Old"}}"#
        let newer = #"{"ctx":{"subscriptionTier":"SuperGrok Heavy","config":{"creditUsagePercent":5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-10-08T16:32:48Z"}}}}"#
        let snap = parseSubscriptionLog(older + "\n" + newer)
        XCTAssertEqual(snap?.plan, "SuperGrok Heavy")
        XCTAssertEqual(snap?.percentUsed, 5)
        XCTAssertEqual(snap?.percentLeft, 95)
        XCTAssertEqual(snap?.resetsAt, "2026-10-08")
    }
}
