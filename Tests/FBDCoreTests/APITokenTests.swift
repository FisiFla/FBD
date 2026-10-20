import XCTest
import FBDCore

/// The shared API-token comparison (issue #32: one implementation instead of
/// two copies) and the guidance printed instead of the secret.
final class APITokenTests: XCTestCase {
    func testMatchingTokenIsAccepted() {
        XCTAssertTrue(APIToken.matches("s3cret", "s3cret"))
    }

    func testMismatchedTokenIsRejected() {
        XCTAssertFalse(APIToken.matches("s3cret", "other"))
        XCTAssertFalse(APIToken.matches("s3cre", "s3cret"))
        XCTAssertFalse(APIToken.matches("s3crett", "s3cret"))
    }

    func testMissingOrEmptyProvidedTokenIsRejected() {
        XCTAssertFalse(APIToken.matches(nil, "s3cret"))
        XCTAssertFalse(APIToken.matches("", "s3cret"))
    }

    /// Fails closed: an unavailable token (empty) must reject every request,
    /// not accept them.
    func testEmptyExpectedTokenRejectsEverything() {
        XCTAssertFalse(APIToken.matches("s3cret", ""))
        XCTAssertFalse(APIToken.matches("", ""))
        XCTAssertFalse(APIToken.matches(nil, ""))
    }

    /// The instructions must never contain the token itself.
    func testRevealInstructionsDoNotLeakAToken() {
        let token = "0123456789abcdef0123456789abcdef"
        XCTAssertFalse(APIToken.revealInstructions.contains(token))
        XCTAssertTrue(APIToken.revealInstructions.contains("--reveal"))
    }
}
