import FBDCore
import XCTest
@testable import FBDCLIParser

/// The parser library has no FBDCore dependency, so the one constant it
/// mirrors is checked against the core here.
final class StreamFrameRateAgreementTests: XCTestCase {
    func testAllowedFrameRatesMatchTheCore() {
        XCTAssertEqual(StreamOptions.allowedFrameRates, StreamFrameRate.range)
    }
}
