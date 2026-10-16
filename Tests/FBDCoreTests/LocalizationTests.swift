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
    ///
    /// Format keys (what an interpolated string compiles to) are checked through their literal
    /// segments instead — see `literalSegments`, which the test below pins.
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
                sourceUses(key, in: source),
                "no call site uses \"\(key)\" any more — the key has drifted"
            )
        }
    }

    /// A translation may only use the key's arguments, in the key's order: a `%lld` that became
    /// `%@` crashes (or prints garbage) at runtime, and the key-set check above cannot see it.
    /// Dropping an argument is allowed — "%lld display%@" has no plural suffix in Chinese.
    func testFormatSpecifiersMatchAcrossLanguages() throws {
        let entries = try allEntries()
        guard let reference = entries["en"] else { return XCTFail("no en entries") }
        for language in Self.languages where language != "en" {
            for (key, value) in entries[language] ?? [:] {
                XCTAssertTrue(
                    Self.isSubsequence(Self.specifiers(in: value), of: Self.specifiers(in: key)),
                    "\(language) changes the format specifiers of \"\(key)\""
                )
            }
        }
        for (key, value) in reference {
            XCTAssertEqual(Self.specifiers(in: value), Self.specifiers(in: key), "en value of \"\(key)\" changes its specifiers")
        }
    }

    /// The reverse of `testEveryKeyStillExistsInTheSource`: every plain user-facing literal in the
    /// app's views must have a key, or it silently stays English in the other languages.
    /// Interpolated strings (format keys) and non-literal arguments are not checked here.
    func testEveryUserFacingLiteralHasAKey() throws {
        let keys = Set(try parse(stringsURL("en")).keys)
        let root = packageRoot.appendingPathComponent("Sources/FBD")
        let pattern = try NSRegularExpression(
            pattern: #"(?:\b(?:Text|Button|Label|Toggle|Menu|Picker|TextField|Link)\(|\.(?:help|accessibilityLabel|accessibilityHint)\(|String\(localized:\s*|NSLocalizedString\(|\bfbdConfirmation\(|\bconfirmationDialog\(|\bconfirm:\s*|\bmessage:\s*)\s*"((?:[^"\\]|\\.)*)""#
        )
        var missing: [String] = []
        for file in try FileManager.default.subpaths(atPath: root.path) ?? [] where file.hasSuffix(".swift") {
            guard !file.hasSuffix("make_icon.swift") else { continue }
            let text = (try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)) ?? ""
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let literal = String(text[range])
                // Interpolations, and text with no letters in it ("—", "°"), are not keys.
                // Nor are bare multipliers such as "4x".
                guard !literal.contains("\\("), literal.contains(where: \.isLetter),
                      !(literal.first?.isNumber ?? false && !literal.contains(" ")) else { continue }
                if !keys.contains(literal) { missing.append("\(file): \"\(literal)\"") }
            }
        }
        XCTAssertEqual(missing, [], "user-facing literals with no en key:\n" + missing.joined(separator: "\n"))
    }

    static func isSubsequence(_ small: [String], of large: [String]) -> Bool {
        var rest = large[...]
        for item in small {
            guard let index = rest.firstIndex(of: item) else { return false }
            rest = rest[(index + 1)...]
        }
        return true
    }

    /// The printf-style specifiers of a string, in order (`%%` excluded).
    static func specifiers(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"%(?:\d+\$)?[-+0#]*\d*(?:\.\d+)?(?:lld|ld|hh|h|l|d|u|f|@|s)"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// The helper the source check leans on for format keys: they are split on their placeholders so
    /// each literal word between them can still be looked for. A key with *no* placeholder yields
    /// nothing, which is how `sourceUses` tells the two kinds apart.
    func testFormatKeysAreSplitIntoTheirLiteralSegments() {
        XCTAssertEqual(LocalizationTests.literalSegments(of: "%lld nits"), ["nits"])
        XCTAssertEqual(LocalizationTests.literalSegments(of: "%lld display%@"), ["display"])
        XCTAssertEqual(LocalizationTests.literalSegments(of: "%@ · %@ · %@"), ["·", "·"])
        XCTAssertEqual(LocalizationTests.literalSegments(of: "General"), [])
    }

    /// Whether the app's sources still use `key`.
    ///
    /// A plain key *is* the literal text, so it has to appear verbatim. A **format** key is what
    /// SwiftUI makes of an interpolated string — `Text("\(nits) nits")` looks up `%lld nits` — so it
    /// never appears verbatim; for those, each literal segment between placeholders must still appear.
    /// That keeps the guard meaningful (renaming `nits` to `dots` in the source stops the segment
    /// being found) without pretending an interpolated string is spelled out somewhere.
    private func sourceUses(_ key: String, in source: String) -> Bool {
        if source.contains("\"\(key)\"") { return true }
        let segments = Self.literalSegments(of: key)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { source.contains($0) }
    }

    /// The literal text between a format key's placeholders, ignoring whitespace-only runs. Empty for
    /// a key with no placeholder, which is what `sourceUses` needs to tell the two apart.
    static func literalSegments(of key: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"%(@|lld|ld|d|\.\d+f|f|u|%)"#) else {
            return []
        }
        let whole = NSRange(key.startIndex..., in: key)
        let matches = regex.matches(in: key, range: whole)
        guard !matches.isEmpty else { return [] }

        var segments: [String] = []
        var last = key.startIndex
        for match in matches {
            guard let range = Range(match.range, in: key) else { continue }
            let raw = String(key[last..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !raw.isEmpty { segments.append(raw) }
            last = range.upperBound
        }
        let tail = String(key[last...]).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { segments.append(tail) }
        return segments
    }
}
