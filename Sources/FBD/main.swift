import AppKit

// App entry point. The full menu-bar UI lives in this target.
// Top-level code runs on the main thread, so the MainActor-isolated
// setup below is safe.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
}
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
