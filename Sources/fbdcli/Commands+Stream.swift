import FBDCLIParser
import FBDCore
import CoreGraphics
import Foundation

// MARK: - Picture-in-picture / stream

/// `fbdcli pip list` — enumerate capturable sources (displays, windows, apps).
/// `fbdcli pip <display-id> [b] [c] [s]` — stream a display.
/// `fbdcli pip --window <window-id> [b] [c] [s]` — stream one window.
/// `fbdcli pip --app <bundle-id> [b] [c] [s]` — stream every window of an app.
/// `fbdcli pip stop` — stop the CLI's own stream.
///
/// The command keeps the window alive until it closes or a key is pressed.
/// The app's PiP is owned by the app process and cannot be touched from here.
/// Process-wide PiP controller so `pip start`/`pip stop` share state.
@MainActor
private let cliPip = PipStreamController()

@MainActor
func cmdPip(_ controller: DisplayController, args: [String]) -> Int32 {
    switch PiPArgs.parse(args) {
    case .failure(let failure):
        print("fbdcli: pip: \(failure.message)")
        return 1
    case .success(let parsed):
        switch parsed.action {
        case .stop:
            cliPip.stop()
            print("pip stopped")
            return 0
        case .list:
            return cmdPipList()
        case .start:
            guard !parsed.sources.isEmpty else {
                print("fbdcli: pip: no capture source")
                return 1
            }
            var sources: [PiPCaptureSource] = []
            for sourceArgs in parsed.sources {
                // A display id gets the same early validation the display-only form
                // used to do; window and app ids are resolved by ScreenCaptureKit,
                // which reports an unknown one itself.
                if case .display(let displayID) = sourceArgs,
                   requireDisplay(String(displayID), in: controller) == nil {
                    return 1
                }
                switch sourceArgs {
                case .display(let id): sources.append(.display(id))
                case .window(let id): sources.append(.window(id))
                case .application(let bundleID): sources.append(.application(bundleID))
                }
            }
            // One shared controller instance for start and stop — a local
            // throwaway instance could never be stopped by `pip stop`.
            let filter = VideoFilter(
                brightness: parsed.filter[0], contrast: parsed.filter[1], saturation: parsed.filter[2]
            )
            // Several sources run side by side: the controller keys a session by its
            // source, so starting the second one no longer closes the first. A start
            // that fails tears the whole invocation down rather than leaving a window
            // the user did not ask for standing on its own.
            for source in sources {
                guard cliPip.startPiP(
                    source: source,
                    filter: filter,
                    fps: parsed.fps,
                    containCursor: parsed.containCursor
                ) else {
                    print("fbdcli: pip: failed to start PiP for \(source.identifier) (grant Screen Recording to FBD if prompted)")
                    cliPip.stop()
                    return 2
                }
            }
            // isActive flips true asynchronously once a capture stream starts, so wait
            // for every one of them before claiming success.
            let startDeadline = Date().addingTimeInterval(5)
            func allStreaming() -> Bool { sources.allSatisfy { cliPip.isActive($0.identifier) } }
            while !allStreaming(), Date() < startDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            guard allStreaming() else {
                print("fbdcli: pip: stream failed to start (screen-recording permission?)")
                cliPip.stop()
                return 2
            }
            let startFrames = cliPip.deliveredFrames
            let startTime = Date()
            for source in sources {
                print("pip streaming \(source.identifier) (brightness \(parsed.filter[0]), contrast \(parsed.filter[1]), saturation \(parsed.filter[2]))")
            }
            if sources.count > 1 {
                print("\(sources.count) PiP windows open — one per capture source")
            }
            print("press any key to stop")
            while cliPip.isActive, !stdinHasInput() {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            // Report the observed rate, not the requested one: the frame-rate
            // cap is only verified by counting what actually arrived. Read
            // before the teardown disposes of the session.
            let elapsed = Date().timeIntervalSince(startTime)
            let delivered = cliPip.deliveredFrames &- startFrames
            cliPip.stop()
            if elapsed >= 0.5 {
                print(String(
                    format: "pip stopped — %d frames in %.1fs = %.1f fps (requested %@)",
                    Int(delivered), elapsed, Double(delivered) / elapsed,
                    StreamFrameRate.label(fps: parsed.fps)
                ))
            } else {
                print("pip stopped")
            }
            return 0
        }
    }
}

/// `fbdcli pip list` — print the capturable sources. `availableSources()` is
/// async, so the run loop is spun the same way `isActive` is awaited above.
@MainActor
func cmdPipList() -> Int32 {
    var sources: [PiPCaptureCandidate] = []
    var finished = false
    Task { @MainActor in
        sources = await cliPip.availableSources()
        finished = true
    }
    let deadline = Date().addingTimeInterval(15)
    while !finished, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    guard finished else {
        print("fbdcli: pip: listing sources timed out — is Screen Recording granted to your terminal?")
        return 2
    }
    guard !sources.isEmpty else {
        print("fbdcli: pip: no capturable sources — is Screen Recording granted to your terminal?")
        return 2
    }
    for candidate in sources {
        print("\(candidate.source.identifier)\t\(candidate.label)")
    }
    return 0
}

@MainActor
func cmdStream(_ controller: DisplayController, args: [String]) -> Int32 {
    switch StreamArgs.parse(args) {
    case .failure(let failure):
        print("fbdcli: stream: \(failure.message)")
        return 1
    case .success(let parsed):
        switch parsed.action {
        case .stop:
            cliPip.stop()
            print("stream stopped")
            return 0
        case .start:
            guard let sourceID = parsed.sourceDisplayID, let targetID = parsed.targetDisplayID,
                  let source = requireDisplay(String(sourceID), in: controller),
                  let target = requireDisplay(String(targetID), in: controller) else {
                return 1
            }
            let filter = VideoFilter(
                brightness: parsed.filter[0], contrast: parsed.filter[1], saturation: parsed.filter[2]
            )
            guard cliPip.startPiP(
                source: .display(source.id),
                on: target.id,
                presentation: .fullScreen,
                filter: filter,
                fps: parsed.fps,
                containCursor: parsed.containCursor
            ) else {
                print("fbdcli: stream: failed to stream display \(source.id) onto \(target.id) (grant Screen Recording to FBD if prompted)")
                return 2
            }
            // As with pip, isActive flips true asynchronously once the capture
            // stream starts — give it a few seconds before declaring failure.
            let startDeadline = Date().addingTimeInterval(3)
            while !cliPip.isActive, Date() < startDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            guard cliPip.isActive else {
                print("fbdcli: stream: capture did not start for display \(source.id) (screen-recording permission?)")
                return 2
            }
            print("streaming display \(source.id) onto display \(target.id) (brightness \(parsed.filter[0]), contrast \(parsed.filter[1]), saturation \(parsed.filter[2]))")
            print("press any key to stop")
            while cliPip.isActive, !stdinHasInput() {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            cliPip.stop()
            print("stream stopped")
            return 0
        }
    }
}

/// True when a byte (or EOF) is available on stdin — the interactive "press
/// any key to stop" for the pip/osd commands. Non-blocking; restores flags.
func stdinHasInput() -> Bool {
    let flags = fcntl(0, F_GETFL, 0)
    guard flags >= 0 else { return false }
    _ = fcntl(0, F_SETFL, flags | O_NONBLOCK)
    var byte: UInt8 = 0
    let count = read(0, &byte, 1)
    _ = fcntl(0, F_SETFL, flags)
    // 1 = a key was pressed, 0 = EOF (piped stdin closed). -1/EAGAIN = idle.
    return count != -1
}
