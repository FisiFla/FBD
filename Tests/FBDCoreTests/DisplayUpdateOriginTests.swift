import XCTest
@testable import FBDCore

/// Where a display change came from.
///
/// The origin is what keeps FBD's HUD from announcing changes the hardware
/// made on its own — the brightness keys, the ambient-light sensor, another
/// application. The update is still posted (the UI keeps refreshing); only the
/// announcement is filtered.
final class DisplayUpdateOriginTests: XCTestCase {
    private func makeDisplay(id: CGDirectDisplayID = 7) -> Display {
        Display(
            id: id,
            name: "Test Display",
            isBuiltin: false,
            vendorNumber: 0x1234,
            modelNumber: 0x5678,
            serialNumber: 42,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            isOnline: true,
            isActive: true
        )
    }

    /// A post that does not say where it came from is a change FBD made: every
    /// change FBD makes is a change the user asked for.
    func testAPostWithoutAnOriginIsAUserChange() {
        let note = Notification(name: .fbdDisplayUpdated, userInfo: ["displayID": 1])
        XCTAssertEqual(note.fbdUpdateOrigin, .user)
    }

    func testAUserChangeReadsAsUser() {
        let note = Notification(
            name: .fbdDisplayUpdated,
            userInfo: [DisplayUpdateOrigin.userInfoKey: DisplayUpdateOrigin.user.rawValue]
        )
        XCTAssertEqual(note.fbdUpdateOrigin, .user)
    }

    func testAHardwareBrightnessChangeIsAnnouncedAsHardware() {
        let display = makeDisplay()
        let posted = expectation(description: "the update is posted")
        var received: Notification?
        let token = NotificationCenter.default.addObserver(
            forName: .fbdDisplayUpdated,
            object: nil,
            queue: nil
        ) { note in
            received = note
            posted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        BrightnessChangeObserver.applyHardwareChange(displayID: display.id, brightness: 0.42, to: display)

        wait(for: [posted], timeout: 2)
        XCTAssertEqual(received?.fbdUpdateOrigin, .hardware)
        XCTAssertEqual((received?.userInfo?["displayID"] as? NSNumber)?.uint32Value, display.id)
        XCTAssertEqual(display.brightness ?? 0, 0.42, accuracy: 0.001)
    }

    func testTheHardwareBrightnessIsClamped() {
        let display = makeDisplay()
        BrightnessChangeObserver.applyHardwareChange(displayID: display.id, brightness: 1.8, to: display)
        XCTAssertEqual(display.brightness ?? 0, 1.0, accuracy: 0.001)

        let other = makeDisplay(id: 8)
        BrightnessChangeObserver.applyHardwareChange(displayID: other.id, brightness: -0.4, to: other)
        XCTAssertEqual(other.brightness ?? 1, 0.0, accuracy: 0.001)
    }
}
