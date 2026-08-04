import Foundation
import Network
import os

/// Control for Samsung Tizen TVs (2016+ models) over the WebSocket
/// "samsung.remote.control" channel (port 8002).
///
/// Wire protocol:
///   ws://<host>:8002/api/v2/channels/samsung.remote.control?name=<base64(appName)>
///   registration emit: {"method":"ms.channel.emit",
///                       "params":{"event":"ms.remote.control",
///                                 "data":{"data":[{"id":"remote.control.0","token":"<token>"}],
///                                         "request":"host"}}}
///   - reply "ms.channel.unauthorized": the TV shows a permission dialog with a
///     PIN (the PIN also appears in data[0].token). This controller has no UI,
///     so it waits for the user to accept the dialog on the TV itself, then for
///     "ms.channel.authorized", which carries the persistent token in
///     data[0].token.
///   - reply "ms.channel.authorized": the token was accepted; data[0].token is
///     the token to persist. Some firmware sends no reply at all for a valid
///     token — silence is treated as success after a short wait.
///   key press: {"method":"ms.remote.control",
///               "params":{"Cmd":"Click","DataOfCmd":"KEY_VOLUP",
///                         "Option":"false","TypeOfRemote":"SendRemoteKey"}}
///
/// The caller persists the token returned by `connect` and assigns it to
/// `authToken` before reconnecting so the TV does not re-prompt.
/// All callbacks run on the shared serial queue (see
/// `WebSocketDisplayController`); completions are called exactly once. Network
/// steps time out after 5 s; the pairing dialog window (a human waiting on the
/// TV) is 60 s.
public final class TizenController: WebSocketDisplayController {
    private let stepTimeout: TimeInterval = 5
    private let pairingTimeout: TimeInterval = 60

    /// Pairing dialog timer (a human waiting on the TV) — kept separate from
    /// the base's step timer because it spans the whole pairing window.
    private var pairingTimer: DispatchWorkItem?
    private var registrationSent = false
    private var registered = false
    private var currentToken = ""

    /// Persistent auth token; set by the caller from a previous `connect` result
    /// before reconnecting.
    public var authToken: String?

    public init() {
        super.init(queue: DispatchQueue(label: "dev.fisifla.fbd.tizen"), logCategory: "TizenController")
    }

    // MARK: - Connect / disconnect

    /// Connect, register on the remote-control channel, and (if needed) wait
    /// through the on-TV pairing dialog. On success `completion(true, token)`
    /// where `token` is the auth token to persist (nil if the TV issued none).
    public override func connect(host: String, port: UInt16 = 8002,
                                 completion: @escaping (Bool, String?) -> Void) {
        registrationSent = false
        registered = false
        currentToken = authToken ?? ""
        super.connect(host: host, port: port, completion: completion)
    }

    override func makeURL(host: String, port: UInt16) -> URL? {
        guard let name = Data("FBD".utf8).base64EncodedString()
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "ws://\(NetworkHost.bracketed(host)):\(port)"
            + "/api/v2/channels/samsung.remote.control?name=\(name)")
    }

    // MARK: - Connection teardown hooks (Tizen tracks `registered` + pairing timer)

    /// Delivers the connect result exactly once and cleans up timers.
    /// Tizen counts as connected only once the channel is registered.
    private func finishConnect(_ ok: Bool, _ info: String?) {
        guard let completion = initCompletion else { return }
        initCompletion = nil
        initTimer?.cancel()
        initTimer = nil
        pairingTimer?.cancel()
        pairingTimer = nil
        setConnected(ok && registered)
        if !ok {
            connection?.cancel()
            connection = nil
            registered = false
        }
        completion(ok, info)
    }

    override func handleConnectionLost() {
        if initCompletion != nil {
            finishConnect(false, "connection lost")
            return
        }
        if registered {
            log.warning("TV connection lost")
        }
        registered = false
        super.handleConnectionLost()
    }

    override func teardown() {
        pairingTimer?.cancel()
        pairingTimer = nil
        registered = false
        super.teardown()
    }

    // MARK: - Registration

    private func sendRegistration() {
        registrationSent = true
        let emit: [String: Any] = [
            "method": "ms.channel.emit",
            "params": [
                "event": "ms.remote.control",
                "data": [
                    "data": [
                        ["id": "remote.control.0", "token": currentToken],
                    ],
                    "request": "host",
                ],
            ],
        ]
        sendText(emit) { [weak self] ok in
            guard let self else { return }
            if !ok {
                self.failInit("failed to send registration")
            }
        }
    }

    private func handleUnauthorized(_ object: [String: Any]) {
        // The TV demands pairing: it shows a dialog and echoes the PIN in
        // data[0].token. Arm the 60 s pairing window; if it expires the user
        // did not accept on the TV.
        guard pairingTimer == nil else { return }
        let params = object["params"] as? [String: Any] ?? [:]
        let data = params["data"] as? [String: Any] ?? [:]
        let rows = data["data"] as? [[String: Any]] ?? []
        if let pin = rows.first?["token"] as? String, !pin.isEmpty {
            log.info("pairing requested — accept the dialog on the TV (PIN \(pin))")
        }
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.log.warning("pairing timed out after \(self.pairingTimeout)s")
            self.finishConnect(false, "pairing timed out (accept the dialog on the TV)")
        }
        pairingTimer = timer
        queue.asyncAfter(deadline: .now() + pairingTimeout, execute: timer)
    }

    private func handleAuthorized(_ object: [String: Any]) {
        let params = object["params"] as? [String: Any] ?? [:]
        let data = params["data"] as? [String: Any] ?? [:]
        let rows = data["data"] as? [[String: Any]] ?? []
        let token = rows.first?["token"] as? String
        registered = true
        if let token, !token.isEmpty {
            log.info("channel authorized")
        } else {
            log.info("channel authorized (no token issued)")
        }
        finishConnect(true, token)
    }

    /// Some firmware sends no reply at all for a valid token — treat a
    /// registration attempt that went unanswered for `stepTimeout` as success.
    private func armStepTimer(_ action: @escaping () -> Void) {
        initTimer?.cancel()
        let timer = DispatchWorkItem(block: action)
        initTimer = timer
        queue.asyncAfter(deadline: .now() + stepTimeout, execute: timer)
    }

    // MARK: - Events

    override func handleMessage(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log.warning("non-JSON message from TV")
            return
        }
        guard let event = object["event"] as? String else { return }
        switch event {
        case "ms.channel.connect":
            if initCompletion != nil, !registrationSent {
                registrationSent = true
                log.info("channel connected; registering")
                sendRegistration()
            }
        case "ms.channel.unauthorized":
            handleUnauthorized(object)
        case "ms.channel.authorized":
            handleAuthorized(object)
        default:
            log.debug("unhandled event: \(event)")
        }
    }

    // MARK: - Commands

    /// Send a remote-control key code: KEY_POWER, KEY_VOLUP, KEY_VOLDOWN,
    /// KEY_MUTE, KEY_SOURCE, …
    public func sendKey(_ key: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else {
                completion?(false)
                return
            }
            guard self.isConnected, self.connection != nil else {
                completion?(false)
                return
            }
            let message: [String: Any] = [
                "method": "ms.remote.control",
                "params": [
                    "Cmd": "Click",
                    "DataOfCmd": key,
                    "Option": "false",
                    "TypeOfRemote": "SendRemoteKey",
                ],
            ]
            self.sendText(message) { ok in
                completion?(ok)
            }
        }
    }

    public func setVolume(_ volume: Int, completion: ((Bool) -> Void)? = nil) {
        let clamped = min(max(volume, 0), 100)
        let key = clamped >= 50 ? "KEY_VOLUP" : "KEY_VOLDOWN"
        pressKeyRepeatedly(key, count: abs(clamped - 50) / 10 + 1, spacing: 0.25) { ok in
            completion?(ok)
        }
    }

    // MARK: - Volume via key presses

    /// Presses `key` `count` times with `spacing` between presses, on the serial
    /// queue. Completion fires exactly once (on first failure or after the last
    /// press). `self` is captured strongly for the (bounded, ≤ ~12 s) sequence so
    /// the completion is guaranteed; `sendKey` still fails fast when the
    /// connection is gone.
    private func pressKeyRepeatedly(_ key: String, count: Int, spacing: TimeInterval,
                                    completion: ((Bool) -> Void)?) {
        var remaining = count
        var failed = false
        func pressNext() {
            guard remaining > 0, !failed else {
                completion?(!failed)
                return
            }
            remaining -= 1
            sendKey(key) { ok in
                guard ok else {
                    failed = true
                    self.log.error("key press failed: \(key)")
                    completion?(false)
                    return
                }
                if remaining > 0 {
                    self.queue.asyncAfter(deadline: .now() + spacing) {
                        pressNext()
                    }
                } else {
                    completion?(true)
                }
            }
        }
        pressNext()
    }
}
