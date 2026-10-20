import Foundation
import XCTest

@testable import FBDCore

/// Runs the generated override script for real — against a temporary root
/// instead of `/Library/Displays`, so the whole mechanism (the Base64 payload,
/// `plutil -lint`, the atomic rename, the cleanup trap, the idempotency of a
/// repeated install and the removal) is exercised without administrator
/// rights. What this cannot cover is the privileged write itself and the
/// display re-enumeration; those need an attached display and a password.
final class HiDPIOverrideInstallScriptTests: XCTestCase {
    func testGeneratedInstallScriptRunsAgainstATemporaryRoot() throws {
        let modes = HiDPILadder.logicalSizes(nativeWidth: 3840, nativeHeight: 2160)
        XCTAssertFalse(modes.isEmpty)
        let script = try HiDPIOverrideCommand.install(vendor: 0x610, product: 0xabcd, serial: 1234, scaledModes: modes)

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fbd-hidpi-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let rewritten = script.replacingOccurrences(of: HiDPIOverrideCommand.overrideRoot, with: root.path)
        XCTAssertNotEqual(rewritten, script)

        func run(_ text: String) throws -> (status: Int32, out: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", text]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        let first = try run(rewritten)
        XCTAssertEqual(first.status, 0, "install script failed: \(first.out)")

        let dest = root.appendingPathComponent("DisplayVendorID-610/DisplayProductID-abcd/DisplaySerialNumber-1234/Contents.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path), "override plist not written")
        let payload = try Data(contentsOf: dest)
        XCTAssertTrue(HiDPIOverrideCommand.overridePlistMatches(payload, scaledModes: modes), "written plist does not carry the ladder")

        // plutil agrees the file is a valid property list
        let lint = Process()
        lint.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        lint.arguments = ["-lint", dest.path]
        try lint.run()
        lint.waitUntilExit()
        XCTAssertEqual(lint.terminationStatus, 0, "plutil -lint rejected the written plist")

        // idempotency: a second run leaves the same bytes and no staging leftovers
        let second = try run(rewritten)
        XCTAssertEqual(second.status, 0, "second install failed: \(second.out)")
        let payload2 = try Data(contentsOf: dest)
        XCTAssertEqual(payload, payload2, "a repeated install changed the file")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".fbd-override.") }
        XCTAssertTrue(leftovers.isEmpty, "staging files were left behind: \(leftovers)")

        // removal
        let removeScript = HiDPIOverrideCommand.remove(path: dest.path)
        let removed = try run(removeScript)
        XCTAssertEqual(removed.status, 0, "remove failed: \(removed.out)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "override plist not removed")
    }
}
