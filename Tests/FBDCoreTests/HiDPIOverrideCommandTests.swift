import XCTest
import FBDCore

/// The HiDPI override command model (issue #27).
///
/// The command is a string, so it can be checked without running anything:
/// it has to parse as a shell script, it must carry nothing but numbers and
/// Base64, and the plist it writes has to say what the ladder says.
final class HiDPIOverrideCommandTests: XCTestCase {
    private let vendor: UInt32 = 0x610
    private let product: UInt32 = 0xabcd
    private let serial: UInt32 = 1234

    private var modes: [HiDPIScaledMode] {
        HiDPILadder.logicalSizes(nativeWidth: 3840, nativeHeight: 2160, minimumScale: 0.5)
    }

    // MARK: - The path

    func testPathUsesTheSerialWhenItIsKnown() {
        let path = HiDPIOverrideCommand.overridePath(vendor: vendor, product: product, serial: serial)

        XCTAssertTrue(path.hasPrefix("/Library/Displays/Contents/Resources/Default/Overrides/"))
        XCTAssertTrue(path.contains("DisplayVendorID-610"))
        XCTAssertTrue(path.contains("DisplayProductID-abcd"))
        XCTAssertTrue(path.contains("DisplaySerialNumber-1234"))
        XCTAssertTrue(path.hasSuffix("/Contents.json"))
    }

    func testPathFallsBackToTheModelFolderWhenTheSerialIsUnknown() {
        let path = HiDPIOverrideCommand.overridePath(vendor: vendor, product: product, serial: 0)

        XCTAssertTrue(path.hasPrefix("/Library/Displays/Contents/Resources/Overrides/"))
        XCTAssertTrue(path.contains("DisplayVendorID-610/DisplayProductID-abcd"))
        XCTAssertFalse(path.contains("DisplaySerialNumber"))
    }

    // MARK: - The install command

    func testInstallCommandTargetsTheDerivedPath() throws {
        let command = try HiDPIOverrideCommand.install(
            vendor: vendor, product: product, serial: serial, scaledModes: modes
        )

        let path = HiDPIOverrideCommand.overridePath(vendor: vendor, product: product, serial: serial)
        XCTAssertTrue(command.contains("'\(path)'"), "the script must write exactly the derived path")
        XCTAssertFalse(command.contains("/bin/cp"), "the script must rename into place, not copy")
    }

    func testInstallCommandCarriesOnlyNumbersAndBase64() throws {
        let command = try HiDPIOverrideCommand.install(
            vendor: vendor, product: product, serial: serial, scaledModes: modes
        )

        // The payload is the only free text in the script, and it is Base64.
        let marker = "/usr/bin/printf '%s' '"
        let start = try XCTUnwrap(command.range(of: marker)).upperBound
        let end = try XCTUnwrap(command[start...].range(of: "'"))
        let payload = String(command[start..<end.lowerBound])
        XCTAssertFalse(payload.isEmpty)
        XCTAssertTrue(payload.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "="
        }, "the payload must be Base64 and nothing else")

        // The path is derived from numbers only.
        let directory = HiDPIOverrideCommand.overrideDirectory(
            vendor: vendor, product: product, serial: serial
        )
        XCTAssertTrue(directory.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == "/"
        }, "the path must be built from numbers and slashes")

        // Nothing else is interpolated: the directory is written three times
        // (the folder, the staged file and the destination) and the payload
        // once.
        XCTAssertEqual(command.components(separatedBy: directory).count - 1, 3)
        XCTAssertEqual(command.components(separatedBy: payload).count - 1, 1)
    }

    func testInstallCommandParsesAsAShellScript() throws {
        let command = try HiDPIOverrideCommand.install(
            vendor: vendor, product: product, serial: serial, scaledModes: modes
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(command.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "the script must parse")
    }

    func testInstallCommandStagesTheFileNextToItsDestination() throws {
        let command = try HiDPIOverrideCommand.install(
            vendor: vendor, product: product, serial: serial, scaledModes: modes
        )

        let directory = HiDPIOverrideCommand.overrideDirectory(
            vendor: vendor, product: product, serial: serial
        )
        XCTAssertTrue(command.contains("/usr/bin/mktemp '\(directory)/.fbd-override.XXXXXXXX'"))
        XCTAssertTrue(command.contains("trap '/bin/rm -f \"$stage\"' EXIT"),
                      "a staged file must be cleaned up on every exit path")
    }

    func testAnEmptyLadderIsRefused() {
        XCTAssertThrowsError(
            try HiDPIOverrideCommand.install(
                vendor: vendor, product: product, serial: serial, scaledModes: []
            )
        ) { error in
            XCTAssertEqual(error as? HiDPIOverrideCommand.CommandError, .emptyLadder)
        }
    }

    func testTooManyModesAreRefused() {
        let tooMany = (0..<(HiDPIOverrideCommand.maxModes + 1)).map {
            HiDPIScaledMode(logicalWidth: 800 + $0, logicalHeight: 600)
        }

        XCTAssertThrowsError(
            try HiDPIOverrideCommand.install(
                vendor: vendor, product: product, serial: serial, scaledModes: tooMany
            )
        ) { error in
            XCTAssertEqual(error as? HiDPIOverrideCommand.CommandError, .tooManyModes)
        }
    }

    // MARK: - The remove command

    func testRemoveCommandTargetsTheDerivedPath() {
        let path = HiDPIOverrideCommand.overridePath(vendor: vendor, product: product, serial: serial)

        let command = HiDPIOverrideCommand.remove(path: path)

        XCTAssertTrue(command.contains("/bin/rm -f '\(path)'"))
    }

    // MARK: - The plist

    func testPlistCarriesTheLadder() throws {
        let plist = try HiDPIOverrideCommand.plistData(for: modes)

        let object = try PropertyListSerialization.propertyList(from: plist, options: [], format: nil)
        let dictionary = try XCTUnwrap(object as? [String: Any])
        let entries = try XCTUnwrap(dictionary["scale-resolutions"] as? [Data])

        XCTAssertEqual(Set(entries), Set(HiDPILadder.scaleResolutions(modes)))
    }

    func testPlistMatchesIsOrderIndependent() throws {
        let reversed = modes.reversed()
        let plist = try HiDPIOverrideCommand.plistData(for: Array(reversed))

        XCTAssertTrue(
            HiDPIOverrideCommand.overridePlistMatches(plist, scaledModes: modes),
            "the same modes in another order are the same override"
        )
    }

    func testPlistMatchesRejectsADifferentLadder() throws {
        let plist = try HiDPIOverrideCommand.plistData(for: modes)

        let other = [HiDPIScaledMode(logicalWidth: 1920, logicalHeight: 1080)]

        XCTAssertFalse(HiDPIOverrideCommand.overridePlistMatches(plist, scaledModes: other))
    }

    func testPlistMatchesRejectsGarbage() {
        XCTAssertFalse(
            HiDPIOverrideCommand.overridePlistMatches(Data("not a plist".utf8), scaledModes: modes)
        )
    }

    // MARK: - The AppleScript literal

    func testAppleScriptLiteralEscapesBackslashesAndQuotes() {
        let escaped = HiDPIOverrideCommand.appleScriptLiteral(#"a\b"c"#)

        XCTAssertEqual(escaped, #"a\\b\"c"#)
    }

    func testAppleScriptLiteralLeavesPlainTextAlone() {
        XCTAssertEqual(
            HiDPIOverrideCommand.appleScriptLiteral("/bin/rm -f '/Library/Displays'"),
            "/bin/rm -f '/Library/Displays'"
        )
    }
}
