import XCTest
@testable import FBDCLIParser

/// The agent skill FBD ships (issue #31): the document, its version stamp,
/// where it is installed, and the byte-for-byte relation between the file and
/// what `--print` writes.
final class AgentSkillTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fbd-skill-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    // MARK: - Where it is installed

    func testDefaultDirectoryPerAgent() {
        XCTAssertEqual(
            AgentSkill.defaultDirectory(for: .claude, home: "/Users/tester"),
            "/Users/tester/.claude/skills/fbd"
        )
        XCTAssertEqual(
            AgentSkill.defaultDirectory(for: .codex, home: "/Users/tester"),
            "/Users/tester/.codex/skills/fbd"
        )
    }

    func testDefaultFileNameIsSkillMarkdown() {
        XCTAssertEqual(AgentSkill.fileName, "SKILL.md")
        XCTAssertEqual(
            AgentSkill.filePath(for: .claude, directory: nil, home: "/Users/tester"),
            "/Users/tester/.claude/skills/fbd/SKILL.md"
        )
    }

    func testPathOverrideWins() {
        XCTAssertEqual(
            AgentSkill.filePath(for: .codex, directory: "/tmp/elsewhere", home: "/Users/tester"),
            "/tmp/elsewhere/SKILL.md"
        )
    }

    func testHomeIsExpandedInAnOverride() {
        XCTAssertEqual(
            AgentSkill.filePath(for: .codex, directory: "~/skills/fbd", home: "/Users/tester"),
            "/Users/tester/skills/fbd/SKILL.md"
        )
    }

    // MARK: - Installing

    func testInstallWritesTheDocument() throws {
        let path = try AgentSkill.install(target: .claude, directory: temporaryDirectory.path, home: "/Users/tester")
        XCTAssertEqual(path, temporaryDirectory.path + "/SKILL.md")
        let written = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(written, AgentSkill.payload(for: .claude))
    }

    func testInstallCreatesTheDirectory() throws {
        let nested = temporaryDirectory.path + "/a/b/c"
        let path = try AgentSkill.install(target: .codex, directory: nested, home: "/Users/tester")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testInstallOverwritesAnOlderDocument() throws {
        let path = temporaryDirectory.path + "/SKILL.md"
        try FileManager.default.createDirectory(
            atPath: temporaryDirectory.path,
            withIntermediateDirectories: true
        )
        try Data("an older skill".utf8).write(to: URL(fileURLWithPath: path))

        _ = try AgentSkill.install(target: .claude, directory: temporaryDirectory.path, home: "/Users/tester")

        let written = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(written, AgentSkill.payload(for: .claude))
        XCTAssertFalse(String(decoding: written, as: UTF8.self).contains("an older skill"))
    }

    /// `--print` writes exactly `AgentSkill.payload`, and the installed file
    /// is exactly the same bytes — so an agent that reads the file and a
    /// caller that prints it see the same document.
    func testPrintMatchesTheInstalledFileByteForByte() throws {
        let path = try AgentSkill.install(target: .claude, directory: temporaryDirectory.path, home: "/Users/tester")
        let printed = AgentSkill.payload(for: .claude)
        let written = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(printed, written)
        XCTAssertEqual(printed, Data(AgentSkill.text(for: .claude).utf8))
    }

    func testTheTwoAgentsGetTheirOwnDocuments() {
        XCTAssertNotEqual(AgentSkill.text(for: .claude), AgentSkill.text(for: .codex))
        XCTAssertTrue(AgentSkill.text(for: .claude).contains("~/.claude/skills/<name>/"))
        XCTAssertTrue(AgentSkill.text(for: .codex).contains("~/.codex/skills/<name>/"))
    }

    // MARK: - The document itself

    func testTheDocumentIsVersionStamped() {
        let text = AgentSkill.text(for: .claude)
        XCTAssertTrue(text.contains("version: \(AgentSkill.version)"))
        XCTAssertTrue(text.contains("Skill version \(AgentSkill.version)"))
    }

    func testTheDocumentHasFrontmatter() {
        let text = AgentSkill.text(for: .claude)
        XCTAssertTrue(text.hasPrefix("---\n"))
        XCTAssertTrue(text.contains("\nname: fbd\n"))
        XCTAssertTrue(text.contains("\ndescription: \""))
    }

    func testTheDocumentTeachesTheTokenModel() {
        let text = AgentSkill.text(for: .claude)
        XCTAssertTrue(text.contains("fbdcli auth-token --reveal"))
        XCTAssertTrue(text.contains("never prints the token itself"))
        XCTAssertTrue(text.contains("never echo it back"))
        XCTAssertTrue(text.contains("Never paste it into"))
    }

    func testTheDocumentTeachesTheReadBackPattern() {
        let text = AgentSkill.text(for: .claude)
        XCTAssertTrue(text.contains("read back, never retry blindly"))
        XCTAssertTrue(text.contains("may have applied"))
        XCTAssertTrue(text.contains("Verify the state with:"))
    }

    func testTheDocumentUsesTheHonestVocabulary() {
        let text = AgentSkill.text(for: .claude)
        XCTAssertTrue(text.contains("not verified on hardware"))
        XCTAssertTrue(text.contains("may have applied"))
    }

    func testTheDocumentCarriesTheGrammarTable() {
        let text = AgentSkill.text(for: .claude)
        XCTAssertTrue(text.contains("| command | what it does | changes state | read back with |"))
        for row in CLIGrammar.rows {
            XCTAssertTrue(
                text.contains("`\(row.usage)`"),
                "the grammar table is missing \(row.usage)"
            )
        }
    }
}
