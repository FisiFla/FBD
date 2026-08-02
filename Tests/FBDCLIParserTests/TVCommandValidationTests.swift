import XCTest
@testable import FBDCLIParser

/// Tests for the `fbdcli tv` argument validator (the CLI's largest
/// free-form validation surface).
final class TVCommandValidationTests: XCTestCase {
    // MARK: - Valid commands

    func testPowerDefaultsWhenNoActionGiven() {
        XCTAssertEqual(
            TVCommandValidation.parse(["lg", "192.168.0.50"]),
            .success(TVCommand(brand: .lg, host: "192.168.0.50", action: .power))
        )
    }

    func testAllBrandsParse() {
        for brand in TVCommand.Brand.allCases {
            guard case .success(let command) = TVCommandValidation.parse([brand.rawValue, "10.0.0.1"]) else {
                XCTFail("\(brand.rawValue) should parse")
                continue
            }
            XCTAssertEqual(command.brand, brand)
        }
    }

    func testBrandsAreCaseInsensitive() {
        XCTAssertEqual(
            TVCommandValidation.parse(["LG", "192.168.0.50"]),
            .success(TVCommand(brand: .lg, host: "192.168.0.50", action: .power))
        )
        XCTAssertEqual(
            TVCommandValidation.parse(["Samsung", "192.168.0.50", "power"]),
            .success(TVCommand(brand: .samsung, host: "192.168.0.50", action: .power))
        )
    }

    func testVolumeParsesAndClampsRange() {
        XCTAssertEqual(
            TVCommandValidation.parse(["lg", "h", "volume", "30"]),
            .success(TVCommand(brand: .lg, host: "h", action: .volume(30)))
        )
        XCTAssertEqual(
            TVCommandValidation.parse(["lg", "h", "volume", "0"]),
            .success(TVCommand(brand: .lg, host: "h", action: .volume(0)))
        )
        XCTAssertEqual(
            TVCommandValidation.parse(["lg", "h", "volume", "100"]),
            .success(TVCommand(brand: .lg, host: "h", action: .volume(100)))
        )
    }

    func testInputParsesName() {
        XCTAssertEqual(
            TVCommandValidation.parse(["yamaha", "h", "input", "HDMI 1"]),
            .success(TVCommand(brand: .yamaha, host: "h", action: .input("HDMI 1")))
        )
    }

    // MARK: - Rejections (message content asserted)

    private func message(_ args: [String]) -> String? {
        if case .failure(let failure) = TVCommandValidation.parse(args) {
            return failure.message
        }
        return nil
    }

    func testMissingArguments() {
        XCTAssertNotNil(message([]))
        XCTAssertNotNil(message(["lg"]))
    }

    func testUnknownBrand() {
        XCTAssertEqual(
            message(["sony", "h"]),
            "unknown brand 'sony' (expected lg, samsung, philips, or yamaha)"
        )
    }

    func testUnknownAction() {
        XCTAssertEqual(
            message(["lg", "h", "reboot"]),
            "unknown action 'reboot' (expected volume, power, or input)"
        )
    }

    func testInvalidVolumeValues() {
        XCTAssertEqual(
            message(["lg", "h", "volume", "101"]),
            "volume: expected a number between 0 and 100 (got '101')"
        )
        XCTAssertEqual(
            message(["lg", "h", "volume", "-1"]),
            "volume: expected a number between 0 and 100 (got '-1')"
        )
        XCTAssertEqual(
            message(["lg", "h", "volume", "loud"]),
            "volume: expected a number between 0 and 100 (got 'loud')"
        )
    }

    func testEmptyInputName() {
        XCTAssertEqual(
            message(["lg", "h", "input"]),
            "input: expected an input name (e.g. 'HDMI1', 'HDMI 1', 'WatchTV')"
        )
    }
}
