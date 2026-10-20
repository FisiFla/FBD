import XCTest
@testable import FBDCLIParser

/// `fbdcli skill install …` argument parsing (issue #31).
final class SkillArgsTests: XCTestCase {
    func testInstallClaude() {
        XCTAssertEqual(
            SkillArgs.parse(["install", "claude"]),
            .install(target: .claude, printOnly: false, path: nil)
        )
    }

    func testInstallCodex() {
        XCTAssertEqual(
            SkillArgs.parse(["install", "codex"]),
            .install(target: .codex, printOnly: false, path: nil)
        )
    }

    func testTargetIsCaseInsensitive() {
        XCTAssertEqual(
            SkillArgs.parse(["install", "Claude"]),
            .install(target: .claude, printOnly: false, path: nil)
        )
    }

    func testPrintFlag() {
        XCTAssertEqual(
            SkillArgs.parse(["install", "codex", "--print"]),
            .install(target: .codex, printOnly: true, path: nil)
        )
    }

    func testPathFlag() {
        XCTAssertEqual(
            SkillArgs.parse(["install", "claude", "--path", "/tmp/fbd-skill"]),
            .install(target: .claude, printOnly: false, path: "/tmp/fbd-skill")
        )
    }

    func testFlagsMayComeBeforeTheTarget() {
        XCTAssertEqual(
            SkillArgs.parse(["install", "--print", "--path", "/tmp/fbd-skill", "codex"]),
            .install(target: .codex, printOnly: true, path: "/tmp/fbd-skill")
        )
    }

    // MARK: - Usage errors

    func testNoArgumentsIsUsage() {
        guard case .usage(let message) = SkillArgs.parse([]) else {
            return XCTFail("`skill` without a subcommand must be a usage error")
        }
        XCTAssertTrue(message.contains("install"))
    }

    func testUnknownSubcommandIsAUsageError() {
        guard case .invalid(let message) = SkillArgs.parse(["uninstall", "claude"]) else {
            return XCTFail("an unknown subcommand must be a usage error")
        }
        XCTAssertTrue(message.contains("uninstall"))
        XCTAssertTrue(message.contains("install"))
    }

    func testUnknownTargetIsAUsageError() {
        guard case .invalid(let message) = SkillArgs.parse(["install", "emacs"]) else {
            return XCTFail("an unknown target must be a usage error")
        }
        XCTAssertTrue(message.contains("emacs"))
        XCTAssertTrue(message.contains("claude"))
    }

    func testMissingTargetIsAUsageError() {
        guard case .invalid = SkillArgs.parse(["install"]) else {
            return XCTFail("`install` without a target must be a usage error")
        }
    }

    func testTwoTargetsIsAUsageError() {
        guard case .invalid = SkillArgs.parse(["install", "claude", "codex"]) else {
            return XCTFail("two targets must be a usage error")
        }
    }

    func testPathWithoutAValueIsAUsageError() {
        guard case .invalid(let message) = SkillArgs.parse(["install", "claude", "--path"]) else {
            return XCTFail("`--path` without a value must be a usage error")
        }
        XCTAssertTrue(message.contains("--path"))
    }

    func testEmptyPathIsAUsageError() {
        guard case .invalid = SkillArgs.parse(["install", "claude", "--path", ""]) else {
            return XCTFail("an empty path must be a usage error")
        }
    }
}
