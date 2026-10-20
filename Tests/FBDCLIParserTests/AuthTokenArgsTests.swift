import XCTest
import FBDCLIParser

/// `fbdcli auth-token` argument parsing (issue #32: the token is a secret,
/// so it is printed only with an explicit `--reveal`).
final class AuthTokenArgsTests: XCTestCase {
    func testNoArgumentsPrintsInstructions() {
        XCTAssertEqual(AuthTokenArgs.parse([]), .instructions)
    }

    func testRevealFlagPrintsTheToken() {
        XCTAssertEqual(AuthTokenArgs.parse(["--reveal"]), .reveal)
    }

    func testUnknownArgumentIsAUsageError() {
        guard case .invalid(let message) = AuthTokenArgs.parse(["--reveal-all"]) else {
            return XCTFail("an unknown flag must be a usage error")
        }
        XCTAssertTrue(message.contains("--reveal"))
    }

    func testUnknownArgumentNeverLeaksTheToken() {
        // A typo must not fall back to printing the secret.
        guard case .invalid = AuthTokenArgs.parse(["--revral"]) else {
            return XCTFail("a typo must not be accepted")
        }
    }
}
