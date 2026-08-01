import CPrivateAPI
import XCTest
@testable import FBDCore

final class DisplayModeMappingTests: XCTestCase {
    /// Build a DisplayMode from a CGS description via the production mapping.
    private func makeMode(
        modeNumber: Int32 = 5,
        flags: Int32 = 0x200000 | 0x1,
        width: Int32 = 1920,
        height: Int32 = 1080,
        pixelsWide: Int32 = 3840,
        pixelsHigh: Int32 = 2160,
        fixPtRefreshRate: Int32 = 60 << 16,
        encoding: String = "testmode"
    ) -> DisplayMode {
        let desc = fbd_make_test_mode(modeNumber, flags, width, height, pixelsWide, pixelsHigh, fixPtRefreshRate, encoding)
        return DisplayMode.from(cgsDescription: desc)
    }

    func testMapsAllFieldsFromCGSDescription() {
        // Arrange
        let modeNumber: Int32 = 5
        let flags: Int32 = 0x200000 | 0x1
        let width: Int32 = 1920
        let height: Int32 = 1080
        let pixelsWide: Int32 = 3840
        let pixelsHigh: Int32 = 2160

        // Act
        let mode = makeMode(
            modeNumber: modeNumber,
            flags: flags,
            width: width,
            height: height,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            fixPtRefreshRate: 60 << 16,
            encoding: "testmode"
        )

        // Assert
        XCTAssertEqual(mode.modeNumber, modeNumber)
        XCTAssertEqual(mode.flags, flags)
        XCTAssertEqual(mode.width, width)
        XCTAssertEqual(mode.height, height)
        XCTAssertEqual(mode.pixelsWide, pixelsWide)
        XCTAssertEqual(mode.pixelsHigh, pixelsHigh)
    }

    func testRefreshRateConvertsFrom16_16FixedPoint() {
        // Act
        let mode = makeMode(fixPtRefreshRate: 60 << 16)

        // Assert
        XCTAssertEqual(mode.refreshRate, 60.0, accuracy: 0.0001)
    }

    func testEncodingPreservedFromZeroTerminatedCString() {
        // Act
        let mode = makeMode(encoding: "testmode")

        // Assert
        XCTAssertEqual(mode.encoding, "testmode")
    }

    func testEncodingPreservedAtFullArrayLength() {
        // Arrange
        let fullLength = String(repeating: "x", count: 128)

        // Act
        let mode = makeMode(encoding: fullLength)

        // Assert
        XCTAssertEqual(mode.encoding, fullLength)
    }

    func testHiDPIFlagMapsToIsHiDPI() {
        // Act
        let mode = makeMode(flags: 0x200000 | 0x1)

        // Assert
        XCTAssertTrue(mode.isHiDPI)
    }

    func testNonHiDPIModeIsNotHiDPI() {
        // Act
        let mode = makeMode(flags: 0x1)

        // Assert
        XCTAssertFalse(mode.isHiDPI)
    }

    func testSafeFlagMapsToIsSafe() {
        // Act
        let safeMode = makeMode(flags: 0x200000 | 0x1)
        let unsafeMode = makeMode(flags: 0x200000)

        // Assert
        XCTAssertTrue(safeMode.isSafe)
        XCTAssertFalse(unsafeMode.isSafe)
    }
}
