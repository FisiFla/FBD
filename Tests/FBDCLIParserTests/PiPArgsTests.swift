import XCTest
@testable import FBDCLIParser

/// `PiPArgs` — the `pip` argument parser covering the original display form
/// plus the added window and application sources.
final class PiPArgsTests: XCTestCase {

    private func parse(_ args: [String]) throws -> PiPArgs {
        switch PiPArgs.parse(args) {
        case .success(let parsed): return parsed
        case .failure(let failure): throw failure
        }
    }

    private func fails(_ args: [String], line: UInt = #line) {
        guard case .failure = PiPArgs.parse(args) else {
            return XCTFail("expected failure for \(args)", line: line)
        }
    }

    // MARK: - Actions

    func testStopAndListTakeNoArguments() throws {
        XCTAssertEqual(try parse(["stop"]).action, .stop)
        XCTAssertEqual(try parse(["list"]).action, .list)
        XCTAssertTrue(try parse(["stop"]).filter == [1, 1, 1])
    }

    func testStopAndListRejectTrailingArguments() {
        fails(["stop", "1"])
        fails(["list", "--window", "3"])
    }

    func testRejectsEmptyArguments() {
        fails([])
    }

    // MARK: - Display source (the original form)

    func testParsesDisplaySourceWithDefaultFilter() throws {
        let parsed = try parse(["7"])
        XCTAssertEqual(parsed.action, .start)
        XCTAssertEqual(parsed.source, .display(7))
        XCTAssertEqual(parsed.filter, [1, 1, 1])
    }

    func testParsesDisplaySourceWithFilterValues() throws {
        let parsed = try parse(["7", "1.5", "0.8", "1.2"])
        XCTAssertEqual(parsed.source, .display(7))
        XCTAssertEqual(parsed.filter, [1.5, 0.8, 1.2])
    }

    func testPartialFilterFillsFromTheFront() throws {
        // Mirrors VideoFilterArgs: leading values set, the rest stay at 1.
        XCTAssertEqual(try parse(["7", "1.5"]).filter, [1.5, 1, 1])
        XCTAssertEqual(try parse(["7", "1.5", "0.5"]).filter, [1.5, 0.5, 1])
    }

    func testRejectsNonNumericDisplayId() {
        fails(["abc"])
    }

    // MARK: - Window source

    func testParsesWindowSource() throws {
        let parsed = try parse(["--window", "42"])
        XCTAssertEqual(parsed.action, .start)
        XCTAssertEqual(parsed.source, .window(42))
        XCTAssertEqual(parsed.filter, [1, 1, 1])
    }

    func testParsesWindowSourceWithFilterValues() throws {
        let parsed = try parse(["--window", "42", "1", "1", "0.5"])
        XCTAssertEqual(parsed.source, .window(42))
        XCTAssertEqual(parsed.filter, [1, 1, 0.5])
    }

    func testRejectsWindowWithoutIdentifier() {
        fails(["--window"])
    }

    func testRejectsNonNumericWindowId() {
        fails(["--window", "frontmost"])
    }

    // MARK: - Application source

    func testParsesApplicationSource() throws {
        let parsed = try parse(["--app", "com.apple.Safari"])
        XCTAssertEqual(parsed.action, .start)
        XCTAssertEqual(parsed.source, .application("com.apple.Safari"))
    }

    func testParsesApplicationSourceWithFilterValues() throws {
        let parsed = try parse(["--app", "com.apple.Safari", "0.9"])
        XCTAssertEqual(parsed.source, .application("com.apple.Safari"))
        XCTAssertEqual(parsed.filter, [0.9, 1, 1])
    }

    func testRejectsApplicationWithoutBundleId() {
        fails(["--app"])
    }

    // MARK: - Filter validation shared with VideoFilterArgs

    func testRejectsNegativeFilterValue() {
        fails(["7", "-1"])
        fails(["--window", "42", "-1"])
    }

    func testRejectsTooManyFilterValues() {
        fails(["7", "1", "1", "1", "1"])
        fails(["--window", "42", "1", "1", "1", "1"])
    }
}
