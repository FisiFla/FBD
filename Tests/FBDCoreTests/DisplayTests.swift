import CoreGraphics
import XCTest
@testable import FBDCore

final class DisplayTests: XCTestCase {
    private func makeDisplay(
        id: CGDirectDisplayID,
        vendor: UInt32 = 0x10AC,
        model: UInt32 = 0x1234,
        serial: UInt32 = 0x5678
    ) -> Display {
        Display(
            id: id,
            name: "Test Display",
            isBuiltin: false,
            vendorNumber: vendor,
            modelNumber: model,
            serialNumber: serial,
            bounds: .zero,
            isOnline: true,
            isActive: true
        )
    }

    func testIdentityKeyUsesVendorModelSerialFormat() {
        // Arrange
        let display = makeDisplay(id: 1, vendor: 0x10AC, model: 0x1234, serial: 0x5678)

        // Act
        let key = display.identityKey

        // Assert
        let expected = "\(UInt32(0x10AC))-\(UInt32(0x1234))-\(UInt32(0x5678))"
        XCTAssertEqual(key, expected)
        XCTAssertEqual(key.components(separatedBy: "-").count, 3)
    }

    func testIsVirtualTrueForVirtualDisplayID() {
        // Arrange
        let display = makeDisplay(id: 0xF0F0)

        // Act
        let isVirtual = display.isVirtual

        // Assert
        XCTAssertTrue(isVirtual)
    }

    func testIsVirtualFalseForPhysicalDisplayID() {
        // Arrange
        let display = makeDisplay(id: 1)

        // Act
        let isVirtual = display.isVirtual

        // Assert
        XCTAssertFalse(isVirtual)
    }

    func testDisplaysWithSameIDAreEqual() {
        // Arrange
        let first = makeDisplay(id: 42)
        let second = makeDisplay(id: 42, vendor: 0x1111, model: 0x2222, serial: 0x3333)

        // Assert
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue)
    }

    func testDisplaysWithDifferentIDsAreNotEqual() {
        // Arrange
        let first = makeDisplay(id: 1)
        let second = makeDisplay(id: 2)

        // Assert
        XCTAssertNotEqual(first, second)
    }

    func testHashableDeduplicatesByIDInSet() {
        // Arrange
        let first = makeDisplay(id: 7)
        let second = makeDisplay(id: 7)

        // Act
        let set = Set([first, second])

        // Assert
        XCTAssertEqual(set.count, 1)
    }
}
