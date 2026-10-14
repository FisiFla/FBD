import Foundation

/// Sends commands to a saved network device.
///
/// A seam, so routing a display's volume to its attached device is assertable
/// without a network — the same posture as `AutomationExecuting`.
public protocol NetworkDeviceCommanding: AnyObject, Sendable {
    /// Set the device's volume, 0…100. `completion` reports whether the device
    /// accepted it; a nil completion means "fire and forget".
    func setVolume(percent: Int, on device: NetworkDevice, completion: ((Bool) -> Void)?)
}

/// The shipped commander: reuses the `Network/` controllers, including the connect
/// step each brand needs before it will accept a command.
///
/// Philips is deliberately **not** supported here, and says so rather than
/// appearing to work: its controller pairs with a PIN the user reads off the TV
/// (`confirmPair(pin:)`), and that pairing does not outlive the controller
/// instance — so a fire-and-forget volume send from a media key cannot complete it.
/// Pairing a Philips set stays a `fbdcli tv philips <host>` (or Settings) action.
public final class NetworkDeviceCommander: NetworkDeviceCommanding {
    public init() {}

    public func setVolume(percent: Int, on device: NetworkDevice, completion: ((Bool) -> Void)? = nil) {
        let clamped = min(max(percent, 0), 100)
        switch device.brand {
        case .lg:
            let tv = LGWebOSController()
            let savedKey = Settings.tvLGClientKey.isEmpty ? nil : Settings.tvLGClientKey
            tv.connect(host: device.host, clientKey: savedKey) { ok, info in
                guard ok else {
                    completion?(false)
                    return
                }
                // LG hands back a client key on first pairing; persisting it is what
                // stops the TV prompting on every later connection.
                if Settings.tvLGClientKey.isEmpty, let info, !info.isEmpty {
                    Settings.tvLGClientKey = info
                }
                tv.setVolume(clamped) { completion?($0) }
            }

        case .samsung:
            let tv = TizenController()
            // First pairing shows a dialog on the TV and the controller waits up to
            // 60 s for it, so this is slower than the other brands by design.
            tv.connect(host: device.host) { ok, _ in
                guard ok else {
                    completion?(false)
                    return
                }
                tv.setVolume(clamped) { completion?($0) }
            }

        case .yamaha:
            let avr = YamahaAVRController()
            avr.host = device.host
            avr.setVolume(clamped) { completion?($0) }

        case .philips:
            completion?(false)
        }
    }
}
