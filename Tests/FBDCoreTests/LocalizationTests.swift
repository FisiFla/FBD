import XCTest
@testable import FBDCore

/// The localisation scaffold: three languages, one key set, and no key that has drifted away
/// from the source.
///
/// These are what make the `.strings` files safe to edit. Without them a translation silently
/// rots — a key renamed in Swift and not in the file simply stops resolving, and the UI falls
/// back to English, which looks like "not translated yet" rather than "broken". The check runs
/// in both directions: the languages must agree with each other, *and* every key must still
/// exist somewhere in the source.
final class LocalizationTests: XCTestCase {
    private static let languages = ["en", "zh-Hans", "zh-Hant"]

    /// The package root, derived from this file's own path — the same way
    /// `BrightnessPreferencesTests` reaches repo files.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/FBDCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package root
    }

    private func stringsURL(_ language: String) -> URL {
        packageRoot.appendingPathComponent("Sources/FBD/Resources/\(language).lproj/Localizable.strings")
    }

    /// `"key" = "value";`, with comments stripped. Deliberately strict: a line that is neither
    /// blank nor a comment nor an entry fails the test rather than being skipped, so a malformed
    /// file cannot pass by being unreadable.
    private func parse(_ url: URL) throws -> [String: String] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var text = raw
        for pattern in [#"/\*.*?\*/"#, #"//[^\n]*"#] {
            let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
            let whole = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: whole, withTemplate: "")
        }
        let entry = try NSRegularExpression(
            pattern: #"^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;"#,
            options: [.anchorsMatchLines]
        )
        var entries: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let candidate = String(line)
            guard !candidate.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let range = NSRange(candidate.startIndex..., in: candidate)
            guard let match = entry.firstMatch(in: candidate, range: range),
                  let keyRange = Range(match.range(at: 1), in: candidate),
                  let valueRange = Range(match.range(at: 2), in: candidate) else {
                XCTFail("unparsed line in \(url.lastPathComponent): \(candidate.trimmingCharacters(in: .whitespaces))")
                continue
            }
            entries[String(candidate[keyRange])] = String(candidate[valueRange])
        }
        return entries
    }

    private func allEntries() throws -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for language in Self.languages {
            result[language] = try parse(stringsURL(language))
        }
        return result
    }

    // MARK: - The files

    func testEveryLanguageHasAFileWithEntries() throws {
        for language in Self.languages {
            let url = stringsURL(language)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "\(language).lproj/Localizable.strings is missing"
            )
            let entries = try parse(url)
            XCTAssertFalse(entries.isEmpty, "\(language) has no entries")
        }
    }

    /// The drift guard that matters: a key added to one language and not the others is a string
    /// that will silently fall back to English in the languages missing it.
    func testAllLanguagesCarryTheSameKeys() throws {
        let entries = try allEntries()
        guard let reference = entries["en"] else { return XCTFail("no en entries") }
        for language in Self.languages where language != "en" {
            let keys = Set((entries[language] ?? [:]).keys)
            let referenceKeys = Set(reference.keys)
            XCTAssertEqual(
                keys.subtracting(referenceKeys), [],
                "\(language) has keys English does not: \(keys.subtracting(referenceKeys).sorted())"
            )
            XCTAssertEqual(
                referenceKeys.subtracting(keys), [],
                "\(language) is missing keys: \(referenceKeys.subtracting(keys).sorted())"
            )
        }
    }

    func testNoTranslationIsEmpty() throws {
        for (language, entries) in try allEntries() {
            for (key, value) in entries {
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(language) has an empty value for \"\(key)\""
                )
            }
        }
    }

    /// The other direction: a key that no SwiftUI call site uses any more will never resolve, so
    /// it is dead weight that hides the fact that a string was renamed. Keys are literal English
    /// text, so "used" means the literal appears somewhere in the app's sources.
    func testEveryKeyStillExistsInTheSource() throws {
        var source = ""
        for file in try FileManager.default.subpaths(atPath: packageRoot.appendingPathComponent("Sources/FBD").path) ?? [] {
            guard file.hasSuffix(".swift") else { continue }
            let url = packageRoot.appendingPathComponent("Sources/FBD").appendingPathComponent(file)
            source += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        XCTAssertFalse(source.isEmpty, "could not read the app's sources")

        for key in try parse(stringsURL("en")).keys {
            XCTAssertTrue(
                source.contains("\"\(key)\""),
                "no call site uses \"\(key)\" any more — the key has drifted"
            )
        }
    }
}
