import Foundation
import OSLog

/// Runs a command with administrator rights.
///
/// The executor is the only part of the HiDPI override flow that needs
/// privilege, and it is deliberately narrow: the command arrives as a
/// finished string, and the executor only decides *who* runs it. A privileged
/// helper that authenticates with Touch ID would replace this protocol and
/// nothing else.
public protocol PrivilegedCommandExecuting {
    /// Run a command and return its output.
    ///
    /// - Throws: the reason the command did not run.
    func run(_ command: String) throws -> String
}

/// Why a privileged command did not run, or did not do what it was asked to.
public enum HiDPIOverrideError: Error, Equatable {
    /// The user dismissed the administrator dialog.
    case privilegeDeclined
    /// The command ran and failed.
    case executionFailed(String)
    /// The display does not take a ladder.
    case unsupportedDisplay
}

/// The executor FBD uses today: an AppleScript one-shot.
///
/// macOS shows its own administrator dialog and FBD never sees a password.
/// The command is escaped into the AppleScript literal, so no character of it
/// can end the string early — the command that runs is exactly the command
/// that was built.
public struct AppleScriptPrivilegeExecutor: PrivilegedCommandExecuting {
    public init() {}

    public func run(_ command: String) throws -> String {
        let source = "do shell script \"\(HiDPIOverrideCommand.appleScriptLiteral(command))\" with administrator privileges"
        return try Self.onMain {
            var errorInfo: NSDictionary?
            guard let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo) else {
                throw HiDPIOverrideError.privilegeDeclined
            }
            if let errorInfo {
                let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
                if number == -128 {
                    // -128 is the "user cancelled" error.
                    throw HiDPIOverrideError.privilegeDeclined
                }
                let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "the privileged command failed"
                throw HiDPIOverrideError.executionFailed(message)
            }
            return result.stringValue ?? ""
        }
    }

    /// NSAppleScript wants the main thread.
    private static func onMain<T>(_ body: () throws -> T) throws -> T {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated { try body() }
        }
        return try DispatchQueue.main.sync { try body() }
    }
}

/// Installs and removes a display's HiDPI ladder.
///
/// The service owns the *decision* — which ladder a display gets, whether an
/// install would ask for a password, whether the ladder is already there —
/// and leaves the *privilege* to the executor.
/// What the override surface reports about a display.
///
/// The fields are the honest ones: whether a ladder is possible at all,
/// whether one is installed, whether installing one would ask for a
/// password, and where the override lives.
public struct HiDPIOverrideState: Equatable, Sendable {
    /// Whether this display can carry a ladder at all.
    public let isSupported: Bool
    /// Whether the ladder is installed right now.
    public let isInstalled: Bool
    /// How many scaled modes the ladder holds.
    public let modeCount: Int
    /// Whether installing it would ask for an administrator password.
    public let wouldPrompt: Bool
    /// Where the override file lives.
    public let path: String

    public init(
        isSupported: Bool,
        isInstalled: Bool,
        modeCount: Int,
        wouldPrompt: Bool,
        path: String
    ) {
        self.isSupported = isSupported
        self.isInstalled = isInstalled
        self.modeCount = modeCount
        self.wouldPrompt = wouldPrompt
        self.path = path
    }
}

public final class HiDPIOverrideService {
    /// The process-wide service.
    public static let shared = HiDPIOverrideService()

    private let executor: PrivilegedCommandExecuting
    private let probe: (UInt32, UInt32) -> Bool
    private let readFile: (String) -> Data?
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "HiDPI")

    public init(
        executor: PrivilegedCommandExecuting = AppleScriptPrivilegeExecutor(),
        probe: @escaping (UInt32, UInt32) -> Bool = { IOServiceProbeAPI.requestProbe(vendor: $0, product: $1) },
        readFile: @escaping (String) -> Data? = { path in
            FileManager.default.contents(atPath: path)
        }
    ) {
        self.executor = executor
        self.probe = probe
        self.readFile = readFile
    }

    /// Whether a display can take a ladder at all.
    ///
    /// A virtual display has no native resolution of its own, and a display
    /// without a vendor number cannot be addressed by an override folder.
    public func isSupported(for display: Display) -> Bool {
        guard !display.isVirtual, !display.isBuiltin, display.vendorNumber != 0 else { return false }
        return nativeResolution(for: display) != nil
    }

    /// The ladder a display would get, or nil when it cannot take one.
    public func ladder(for display: Display) -> [HiDPIScaledMode]? {
        guard let resolution = nativeResolution(for: display) else { return nil }
        let modes = HiDPILadder.logicalSizes(nativeWidth: resolution.width, nativeHeight: resolution.height)
        return modes.isEmpty ? nil : modes
    }

    /// Whether the display already carries the ladder.
    public func isInstalled(for display: Display) -> Bool {
        guard let modes = ladder(for: display) else { return false }
        guard let data = readFile(overridePath(for: display)) else { return false }
        return HiDPIOverrideCommand.overridePlistMatches(data, scaledModes: modes)
    }

    /// Whether installing the ladder would ask for a password.
    ///
    /// The answer is "no" when the override already carries the ladder: a
    /// second install would change nothing, and asking for a password to
    /// change nothing is a lie about what the button does.
    public func smoothScalingWouldPrompt(for display: Display) -> Bool {
        guard ladder(for: display) != nil else { return false }
        return !isInstalled(for: display)
    }

    /// Everything the UI, the CLI and the HTTP API report about a display.
    public func state(for display: Display) -> HiDPIOverrideState {
        let modes = ladder(for: display)
        return HiDPIOverrideState(
            isSupported: modes != nil,
            isInstalled: isInstalled(for: display),
            modeCount: modes?.count ?? 0,
            wouldPrompt: smoothScalingWouldPrompt(for: display),
            path: overridePath(for: display)
        )
    }

    /// Install the ladder for a display.
    ///
    /// The result says what happened, so the caller can tell "the password was
    /// not entered" from "the write failed" — the two need very different
    /// words in front of the user.
    @discardableResult
    public func installSmoothScaling(for display: Display) -> Result<Void, HiDPIOverrideError> {
        guard let modes = ladder(for: display) else { return .failure(.unsupportedDisplay) }
        if isInstalled(for: display) {
            // Already there: nothing to do, and nothing to ask for.
            return .success(())
        }
        let command: String
        do {
            command = try HiDPIOverrideCommand.install(
                vendor: display.vendorNumber,
                product: display.modelNumber,
                serial: display.serialNumber,
                scaledModes: modes
            )
        } catch {
            log.error("installSmoothScaling: the ladder for \(display.id) could not be built: \(String(describing: error))")
            return .failure(.executionFailed(String(describing: error)))
        }
        do {
            _ = try executor.run(command)
        } catch let error as HiDPIOverrideError {
            log.error("installSmoothScaling: the ladder for \(display.id) was not installed: \(String(describing: error))")
            return .failure(error)
        } catch {
            log.error("installSmoothScaling: the ladder for \(display.id) was not installed: \(String(describing: error))")
            return .failure(.executionFailed(String(describing: error)))
        }
        reEnumerate(display)
        return .success(())
    }

    /// Remove the ladder from a display.
    ///
    /// The result says what happened, so the caller can tell "the password was
    /// not entered" from "the write failed".
    @discardableResult
    public func removeSmoothScaling(for display: Display) -> Result<Void, HiDPIOverrideError> {
        let path = overridePath(for: display)
        guard readFile(path) != nil else { return .success(()) }
        let command = HiDPIOverrideCommand.remove(path: path)
        do {
            _ = try executor.run(command)
        } catch let error as HiDPIOverrideError {
            log.error("removeSmoothScaling: the ladder for \(display.id) was not removed: \(String(describing: error))")
            return .failure(error)
        } catch {
            log.error("removeSmoothScaling: the ladder for \(display.id) was not removed: \(String(describing: error))")
            return .failure(.executionFailed(String(describing: error)))
        }
        reEnumerate(display)
        return .success(())
    }

    /// The path of a display's override plist.
    public func overridePath(for display: Display) -> String {
        HiDPIOverrideCommand.overridePath(
            vendor: display.vendorNumber,
            product: display.modelNumber,
            serial: display.serialNumber
        )
    }

    /// The native resolution of a display, in pixels.
    ///
    /// The native resolution is the display's largest pixel mode: the panel's
    /// own grid. A display that only reports point sizes (an external screen
    /// that has never been in a scaled mode) falls back to the active mode.
    public func nativeResolution(for display: Display) -> (width: Int, height: Int)? {
        var best: (width: Int, height: Int)?
        var bestArea = 0
        for mode in display.modes {
            let width = Int(mode.pixelsWide > 0 ? mode.pixelsWide : mode.width)
            let height = Int(mode.pixelsHigh > 0 ? mode.pixelsHigh : mode.height)
            guard width > 0, height > 0 else { continue }
            let area = width * height
            if area > bestArea {
                bestArea = area
                best = (width, height)
            }
        }
        if let best { return best }
        guard let current = display.currentMode else { return nil }
        let width = Int(current.pixelsWide > 0 ? current.pixelsWide : current.width)
        let height = Int(current.pixelsHigh > 0 ? current.pixelsHigh : current.height)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Ask the display stack to re-read the overrides.
    ///
    /// The probe is best effort: the override is on disk either way, and the
    /// display usually picks it up on the next wake.
    private func reEnumerate(_ display: Display) {
        let ok = probe(display.vendorNumber, display.modelNumber)
        if !ok {
            log.notice("the display stack did not re-enumerate display \(display.id); the override takes effect on the next wake")
        }
    }
}
