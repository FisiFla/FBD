import XCTest
@testable import FBDCLIParser

/// `--fps` / `--contain-cursor` argument validation for `pip` and `stream` (#14).
///
/// The criteria call for parser and validation tests for the new arguments, so
/// the focus is on the *rejection* paths: an out-of-range rate must fail loudly
/// rather than silently becoming some other frame rate.
final class StreamOptionsTests: XCTestCase {

    private func pip(_ args: [String]) throws -> PiPArgs {
        switch PiPArgs.parse(args) {
        case .success(let parsed): return parsed
        case .failure(let failure): throw failure
        }
    }

    private func stream(_ args: [String]) throws -> StreamArgs {
        switch StreamArgs.parse(args) {
        case .success(let parsed): return parsed
        case .failure(let failure): throw failure
        }
    }

    private func extractFails(_ args: [String], line: UInt = #line) {
        guard case .failure = StreamOptions.extract(args) else {
            return XCTFail("expected failure for \(args)", line: line)
        }
    }

    // MARK: - Defaults keep existing behaviour

    func testNoOptionsMeansNoRateAndNoContainment() throws {
        // The pre-existing invocation must be untouched: no rate requested, so
        // the stream falls back to StreamFrameRate.default.
        let parsed = try pip(["7", "1", "1", "1"])
        XCTAssertNil(parsed.fps)
        XCTAssertFalse(parsed.containCursor)
    }

    // MARK: - --fps

    func testAcceptsARateWithinRange() throws {
        XCTAssertEqual(try pip(["7", "--fps", "60"]).fps, 60)
        XCTAssertEqual(try pip(["7", "--fps", "1"]).fps, 1)
        XCTAssertEqual(try pip(["7", "--fps", "120"]).fps, 120)
    }

    func testRateComposesWithFilterValues() throws {
        let parsed = try pip(["7", "1.5", "0.8", "1.2", "--fps", "30"])
        XCTAssertEqual(parsed.filter, [1.5, 0.8, 1.2])
        XCTAssertEqual(parsed.fps, 30)
    }

    func testRejectsRateOutsideTheRange() {
        extractFails(["--fps", "0"])
        extractFails(["--fps", "121"])
        extractFails(["--fps", "-5"])
    }

    func testRejectsNonNumericOrMissingRate() {
        extractFails(["--fps", "sixty"])
        extractFails(["--fps"])
    }

    // MARK: - --contain-cursor

    func testContainCursorIsOptIn() throws {
        XCTAssertTrue(try pip(["7", "--contain-cursor"]).containCursor)
        XCTAssertFalse(try pip(["7"]).containCursor)
    }

    func testBothOptionsTogether() throws {
        let parsed = try pip(["--window", "42", "1", "1", "1", "--fps", "24", "--contain-cursor"])
        XCTAssertEqual(parsed.source, .window(42))
        XCTAssertEqual(parsed.fps, 24)
        XCTAssertTrue(parsed.containCursor)
    }

    // MARK: - stream

    func testStreamAcceptsTheSameOptions() throws {
        let parsed = try stream(["1", "3", "--fps", "24", "--contain-cursor"])
        XCTAssertEqual(parsed.sourceDisplayID, 1)
        XCTAssertEqual(parsed.targetDisplayID, 3)
        XCTAssertEqual(parsed.fps, 24)
        XCTAssertTrue(parsed.containCursor)
    }

    func testStreamStillRejectsSourceEqualToTarget() {
        guard case .failure = StreamArgs.parse(["1", "1", "--fps", "30"]) else {
            return XCTFail("expected the source == target rejection to survive")
        }
    }

    func testStreamRejectsAnOutOfRangeRate() {
        guard case .failure = StreamArgs.parse(["1", "3", "--fps", "999"]) else {
            return XCTFail("expected an out-of-range rate to be rejected")
        }
    }

    // MARK: - The option stripper itself

    func testExtractLeavesPositionalsUntouched() {
        guard case .success(let extracted) = StreamOptions.extract(["1", "2", "3", "--fps", "50", "--contain-cursor"]) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(extracted.rest, ["1", "2", "3"])
        XCTAssertEqual(extracted.options.fps, 50)
        XCTAssertTrue(extracted.options.containCursor)
    }

    func testExtractTakesTheLastRateWhenRepeated() {
        // Not an endorsed invocation, but pinning it means a repeated flag has
        // one defined meaning instead of an accidental one.
        guard case .success(let extracted) = StreamOptions.extract(["--fps", "30", "--fps", "60"]) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(extracted.options.fps, 60)
    }
}
