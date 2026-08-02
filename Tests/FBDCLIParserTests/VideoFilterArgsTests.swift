import XCTest
@testable import FBDCLIParser

/// Tests for the `pip <id> [brightness] [contrast] [saturation]` filter
/// argument parser.
final class VideoFilterArgsTests: XCTestCase {
    func testDefaultsToIdentity() throws {
        let values = try XCTUnwrap(try? VideoFilterArgs.parse([]).get())
        XCTAssertEqual(values, [1.0, 1.0, 1.0])
    }

    func testPartialArgumentsFillFromFront() throws {
        let values = try XCTUnwrap(try? VideoFilterArgs.parse(["1.5"]).get())
        XCTAssertEqual(values, [1.5, 1.0, 1.0])
        let two = try XCTUnwrap(try? VideoFilterArgs.parse(["1.5", "0.8"]).get())
        XCTAssertEqual(two, [1.5, 0.8, 1.0])
    }

    func testAllThreeArguments() throws {
        let values = try XCTUnwrap(try? VideoFilterArgs.parse(["1.2", "0.9", "1.4"]).get())
        XCTAssertEqual(values, [1.2, 0.9, 1.4])
    }

    func testZeroAllowed() throws {
        let values = try XCTUnwrap(try? VideoFilterArgs.parse(["0"]).get())
        XCTAssertEqual(values, [0.0, 1.0, 1.0])
    }

    func testTooManyArgumentsRejected() {
        guard case .failure(let failure) = VideoFilterArgs.parse(["1", "1", "1", "1"]) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(failure.message.contains("too many arguments"))
    }

    func testNegativeValuesRejected() {
        guard case .failure(let failure) = VideoFilterArgs.parse(["-1"]) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(failure.message.contains("non-negative"))
    }

    func testGarbageRejected() {
        guard case .failure = VideoFilterArgs.parse(["loud"]) else {
            return XCTFail("expected failure")
        }
    }
}
