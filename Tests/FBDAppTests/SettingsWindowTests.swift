@testable import FBD
import AppKit
import XCTest

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testOpenSettingsNotificationShowsWindow() {
        let controller = SettingsWindowController()
        controller.startObserving()
        XCTAssertFalse(controller.isVisible)
        NotificationCenter.default.post(name: .fbdOpenSettings, object: nil)
        XCTAssertTrue(controller.isVisible)
        controller.close()
    }
}
