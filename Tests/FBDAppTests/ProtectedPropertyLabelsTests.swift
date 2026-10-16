@testable import FBD
import FBDCore
import XCTest

final class ProtectedPropertyLabelsTests: XCTestCase {
    func testNoRawIdentifiers() {
        for entry in ProtectedPropertyLabels.ordered {
            let key = ProtectedPropertyLabels.englishLabel(for: entry)
            XCTAssertFalse(key.contains(where: \.isUppercase) && key.first!.isLowercase,
                           "camelCase identifier leaked: \(key)")
        }
        XCTAssertEqual(ProtectedPropertyLabels.englishLabel(for: .refreshRate), "Refresh rate")
        XCTAssertEqual(ProtectedPropertyLabels.englishLabel(for: .mainStatus), "Main display")
        XCTAssertEqual(ProtectedPropertyLabels.englishLabel(for: .hdrMode), "HDR mode")
    }

    func testOrderedCoversEveryProtectedProperty() {
        let union = ProtectedPropertyLabels.ordered.reduce(into: ProtectedProperties()) { $0.formUnion($1) }
        XCTAssertEqual(union, .all)
        XCTAssertEqual(ProtectedPropertyLabels.ordered.count, ProtectedProperties.ordered.count)
    }
}
