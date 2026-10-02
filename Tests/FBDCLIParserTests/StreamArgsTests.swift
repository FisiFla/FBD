import XCTest
@testable import FBDCLIParser

/// `StreamArgs` — the `stream` argument parser for local streaming.
final class StreamArgsTests: XCTestCase {

    private func parse(_ args: [String]) throws -> StreamArgs {
        switch StreamArgs.parse(args) {
        case .success(let parsed): return parsed
        case .failure(let failure): throw failure
        }
    }

    private func fails(_ args: [String], line: UInt = #line) {
        guard case .failure = StreamArgs.parse(args) else {
            return XCTFail("expected failure for \(args)", line: line)
        }
    }

    func testStopTakesNoArguments() throws {
        XCTAssertEqual(try parse(["stop"]).action, .stop)
    }

    func testStopRejectsTrailingArguments() {
        fails(["stop", "1"])
    }

    func testRejectsEmptyArguments() {
        fails([])
    }

    func testParsesSourceAndTargetWithDefaultFilter() throws {
        let parsed = try parse(["3", "5"])
        XCTAssertEqual(parsed.action, .start)
        XCTAssertEqual(parsed.sourceDisplayID, 3)
        XCTAssertEqual(parsed.targetDisplayID, 5)
        XCTAssertEqual(parsed.filter, [1, 1, 1])
    }

    func testParsesFilterValues() throws {
        let parsed = try parse(["3", "5", "1.4", "0.7", "1.1"])
        XCTAssertEqual(parsed.filter, [1.4, 0.7, 1.1])
    }

    func testRejectsMissingTarget() {
        fails(["3"])
    }

    func testRejectsRedirectingADisplayOntoItself() {
        // Would capture the stream's own window and feed back forever.
        fails(["3", "3"])
    }

    func testRejectsNonNumericDisplayIds() {
        fails(["abc", "5"])
        fails(["3", "abc"])
    }

    func testRejectsNegativeFilterValue() {
        fails(["3", "5", "-1"])
    }

    func testRejectsTooManyFilterValues() {
        fails(["3", "5", "1", "1", "1", "1"])
    }
}
