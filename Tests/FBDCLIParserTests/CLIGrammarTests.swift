import XCTest
@testable import FBDCLIParser

/// The CLI's grammar table: one row per command, the help text and the agent
/// skill's grammar table are checked against it, so none of the three can
/// fall behind the others.
final class CLIGrammarTests: XCTestCase {
    func testEveryCommandHasExactlyOneRow() {
        XCTAssertEqual(CLIGrammar.rows.count, Command.allCases.count)
        for command in Command.allCases {
            XCTAssertNotNil(
                CLIGrammar.row(for: command),
                "\(command.rawValue) has no grammar row"
            )
        }
        let raws = CLIGrammar.rows.map(\.command.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count, "a command has two rows")
    }

    /// Every command must be listed in `fbdcli help`.
    func testEveryCommandAppearsInTheHelpText() {
        for command in Command.allCases {
            XCTAssertTrue(
                UsageText.text.contains("\n  \(command.rawValue) "),
                "\(command.rawValue) is missing from the help text"
            )
        }
    }

    /// Every state-changing command needs a way to read its state back — or
    /// an honest statement that there is none.
    func testEveryStateChangingCommandHasAReadBackOrSaysThereIsNone() {
        for row in CLIGrammar.rows where row.mutating {
            if let readBack = row.readBack {
                XCTAssertTrue(
                    readBack.hasPrefix("fbdcli "),
                    "\(row.command.rawValue): the read-back must be a command"
                )
            }
        }
        // The commands that genuinely have no read-back are listed here, so
        // adding one to the table without a read-back is a deliberate act.
        let withoutReadBack = Set(
            CLIGrammar.rows.filter { $0.mutating && $0.readBack == nil }.map(\.command)
        )
        XCTAssertEqual(withoutReadBack, [.underscan, .pip, .stream, .tv])
    }

    func testTheReadBackSubstitutesTheDisplayID() {
        XCTAssertEqual(
            CLIGrammar.readBack(for: .brightness, id: "7"),
            "fbdcli brightness 7"
        )
        XCTAssertEqual(
            CLIGrammar.readBack(for: .setMode, id: "7"),
            "fbdcli modes 7"
        )
        XCTAssertEqual(
            CLIGrammar.readBack(for: .virtual),
            "fbdcli virtual list"
        )
        XCTAssertNil(CLIGrammar.readBack(for: .tv))
    }

    func testTheReadBackOfACommandWithoutOneIsNil() {
        XCTAssertNil(CLIGrammar.readBack(for: .tv))
        XCTAssertNil(CLIGrammar.readBack(for: .underscan))
    }

    /// The skill teaches the read-back of every state-changing command.
    func testTheSkillCarriesTheReadBackOfEveryStateChangingCommand() {
        let text = AgentSkill.text(for: .claude)
        for row in CLIGrammar.rows where row.mutating {
            guard let readBack = row.readBack else {
                XCTAssertTrue(
                    text.contains("none — the CLI cannot read that state back"),
                    "the skill must say that \(row.command.rawValue) has no read-back"
                )
                continue
            }
            XCTAssertTrue(
                text.contains(readBack),
                "the skill is missing the read-back of \(row.command.rawValue)"
            )
        }
    }
}
