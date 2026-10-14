import XCTest
@testable import FBDCore

/// The `dark-mode` vocabulary. Pure, so it is asserted without a window server — and the two
/// things worth pinning are that no argument means "report", and that a typo is *refused* rather
/// than quietly treated as a read.
final class DarkModeRequestTests: XCTestCase {
    /// No argument is the useful default: running the command should say where things stand.
    func testNoArgumentReportsRatherThanGuesses() {
        XCTAssertEqual(DarkModeRequest.parse(nil), .report)
        XCTAssertEqual(DarkModeRequest.parse(""), .report)
    }

    func testTheExplicitWordsAndTheirAliases() {
        for word in ["on", "dark", "true", "yes", "1", "ON", " Dark "] {
            XCTAssertEqual(DarkModeRequest.parse(word), .on, word)
        }
        for word in ["off", "light", "false", "no", "0", "OFF", " Light "] {
            XCTAssertEqual(DarkModeRequest.parse(word), .off, word)
        }
    }

    func testAskingToReadIsSpellable() {
        for word in ["status", "report", "get"] {
            XCTAssertEqual(DarkModeRequest.parse(word), .report, word)
        }
    }

    /// A typo must be refused: silently reporting would look like success for a write that never
    /// happened, which is the failure mode this area keeps producing.
    func testAnUnknownWordIsRefused() {
        XCTAssertNil(DarkModeRequest.parse("drak"))
        XCTAssertNil(DarkModeRequest.parse("2"))
        XCTAssertNil(DarkModeRequest.parse("toggle"))
    }
}
