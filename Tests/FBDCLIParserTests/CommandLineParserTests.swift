import XCTest
@testable import FBDCLIParser

/// Tests for the fbdcli argument parser (the manual parser that previously
/// lived untested inside the executable).
final class CommandLineParserTests: XCTestCase {
    // MARK: - Bare / help

    func testNoArgumentsIsUsage() {
        XCTAssertEqual(CLICommandLine.parse([]), .usage)
    }

    func testDirectFlagAloneIsUsage() {
        XCTAssertEqual(CLICommandLine.parse(["--direct"]), .usage)
    }

    func testHelpCommand() {
        XCTAssertEqual(CLICommandLine.parse(["help"]), .help)
    }

    // MARK: - Simple commands

    func testList() {
        XCTAssertEqual(CLICommandLine.parse(["list"]), .command(.list, raw: ["list"], direct: false))
    }

    func testBrightnessWithIdAndValue() {
        XCTAssertEqual(
            CLICommandLine.parse(["brightness", "1", "55"]),
            .command(.brightness, raw: ["brightness", "1", "55"], direct: false)
        )
    }

    func testSetModeWithSpec() {
        XCTAssertEqual(
            CLICommandLine.parse(["set-mode", "2", "2560x1440@60"]),
            .command(.setMode, raw: ["set-mode", "2", "2560x1440@60"], direct: false)
        )
    }

    func testAuthToken() {
        XCTAssertEqual(CLICommandLine.parse(["auth-token"]), .command(.authToken, raw: ["auth-token"], direct: false))
    }

    func testTvWithFullArguments() {
        XCTAssertEqual(
            CLICommandLine.parse(["tv", "lg", "192.168.0.50", "volume", "30"]),
            .command(.tv, raw: ["tv", "lg", "192.168.0.50", "volume", "30"], direct: false)
        )
    }

    func testVirtualCreateWithFlags() {
        XCTAssertEqual(
            CLICommandLine.parse(["virtual", "create", "Foo", "1920x1080@60", "--hdr", "--no-auto"]),
            .command(.virtual, raw: ["virtual", "create", "Foo", "1920x1080@60", "--hdr", "--no-auto"], direct: false)
        )
    }

    // MARK: - --direct flag

    func testDirectFlagAtStart() {
        XCTAssertEqual(CLICommandLine.parse(["--direct", "list"]), .command(.list, raw: ["list"], direct: true))
    }

    func testDirectFlagInTheMiddle() {
        XCTAssertEqual(
            CLICommandLine.parse(["brightness", "--direct", "1", "55"]),
            .command(.brightness, raw: ["brightness", "1", "55"], direct: true)
        )
    }

    func testDirectFlagAtEnd() {
        XCTAssertEqual(CLICommandLine.parse(["list", "--direct"]), .command(.list, raw: ["list"], direct: true))
    }

    // MARK: - Unknown commands

    func testUnknownCommandCarriesRawWord() {
        XCTAssertEqual(CLICommandLine.parse(["frobnicate"]), .unknown("frobnicate"))
    }

    func testUnknownCommandWithArguments() {
        XCTAssertEqual(CLICommandLine.parse(["frobnicate", "1", "2"]), .unknown("frobnicate"))
    }

    // MARK: - Vocabulary integrity

    func testEveryCommandRawValueRoundTrips() {
        for command in Command.allCases {
            XCTAssertEqual(Command(rawValue: command.rawValue), command, "raw value \(command.rawValue)")
        }
    }

    func testEveryCommandParsesAsItself() {
        for command in Command.allCases {
            if command == .help {
                // `help` is special-cased to the `.help` result.
                XCTAssertEqual(CLICommandLine.parse(["help"]), .help)
                continue
            }
            guard case .command(let parsed, raw: _, direct: false) = CLICommandLine.parse([command.rawValue]) else {
                XCTFail("\(command.rawValue) did not parse as its own command")
                continue
            }
            XCTAssertEqual(parsed, command)
        }
    }

    func testNoDuplicateRawValues() {
        let raws = Command.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
    }
}
