import AppKit
import FBDCore
import os

/// Application delegate: wires up the composition root and handles the
/// `fbd://` URL scheme.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appCore: AppCore?
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "App")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let core = AppCore()
        core.start()
        appCore = core
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu-bar app — never terminate just because the last window closed.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The listener dies with the process. Leaving the port published would
        // point fbdcli at whatever binds it next.
        Settings.httpServerActivePort = 0
    }

    /// `fbd://` URL scheme: `fbd://brightness/<id>/<value>`, `fbd://open` and
    /// `fbd://close`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            appCore?.handle(url: url)
        }
    }
}
