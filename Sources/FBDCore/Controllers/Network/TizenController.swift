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
/// All callbacks run on a private serial queue; completions are called exactly
/// once. Network steps time out after 5 s; the pairing dialog window (a human
/// waiting on the TV) is 60 s.
public final class TizenController {
    private let queue = DispatchQueue(label: "dev.fisifla.fbd.tizen")
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "TizenController")
    private let stepTimeout: TimeInterval = 5
    private let pairingTimeout: TimeInterval = 60

    private var connection: NWConnection?
    private var connectCompletion: ((Bool, String?) -> Void)?
    private var stepTimer: DispatchWorkItem?
    private var pairingTimer: DispatchWorkItem?
    private var registrationSent = false
    private var registered = false
    private var currentToken = ""

    private let stateLock = NSLock()
    private var _isConnected = false

    /// Persistent auth token; set by the caller from a previous `connect` result
    /// before reconnecting.
    public var authToken: String?

    public var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isConnected
    }

    public init() {}

    // MARK: - Connect / disconnect

    /// Connect, register on the remote-control channel, and (if needed) wait
    /// through the on-TV pairing dialog. On success `completion(true, token)`
    /// where `token` is the auth token to persist (nil if the TV issued none).
    public func connect(host: String, port: UInt16 = 8002,
                        completion: @escaping (Bool, String?) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion(false, "controller deallocated")
                return
            }
            guard self.connection == nil else {
                completion(false, "already connected or connecting")
                return
            }
            self.connectCompletion = completion
            self.registrationSent = false
            self.registered = false
            self.currentToken = self.authToken ?? ""

            // URL(string:) needs IPv6 literals bracketed.
            let displayHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            guard let name = Data("FBD".utf8).base64EncodedString()
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                let url = URL(string: "ws://\(displayHost):\(port)"
                    + "/api/v2/channels/samsung.remote.control?name=\(name)") else {
                self.finishConnect(false, "invalid host or port")
                return
            }

            var params = NWParameters.tcp
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            // NWParameters.ws already carries a WebSocket options object —
            // configure it instead of stacking a second WebSocket protocol.
            if let existing = params.defaultProtocolStack.applicationProtocols.first
                as? NWProtocolWebSocket.Options {
                existing.autoReplyPing = true
            } else {
                params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            }

            let connection = NWConnection(to: .url(url), using: params)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                self?.handleState(state)
            }
            connection.start(queue: self.queue)
            self.receiveLoop()

            // TCP + WS upgrade + channel connect event must happen within 5 s.
            self.armStepTimer { [weak self] in
                self?.finishConnect(false, "connection timed out")
            }
        }
    }

    public func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stepTimer?.cancel()
            self.stepTimer = nil
            self.pairingTimer?.cancel()
            self.pairingTimer = nil
            if let completion = self.connectCompletion {
                self.connectCompletion = nil
                completion(false, "disconnected")
            }
            self.registered = false
            self.connection?.cancel()
            self.connection = nil
            self.setConnected(false)
        }
    }

    // MARK: - Commands

    /// Send a remote-control key code: KEY_POWER, KEY_VOLUP, KEY_VOLDOWN,
    /// KEY_MUTE, KEY_SOURCE, …
    public func sendKey(_ key: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, let connection = self.connection, self.registered else {
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
            self.sendText(message, on: connection) { ok in
                completion?(ok)
            }
        }
    }

    /// Set volume via repeated KEY_VOLUP presses.
    ///
    /// Simple approach: the remote-control channel has no volume query, so the
    /// volume is assumed to start near 0 and KEY_VOLUP is pressed `volume`
    /// times (0…100), spaced 0.12 s apart so the TV can process each press.
    /// The sequence is inherently slow (up to ~12 s) and imprecise — this is a
    /// documented limitation of the press-count approach.
    public func setVolume(_ volume: Int, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else {
                completion?(false)
                return
            }
            let target = min(max(volume, 0), 100)
            self.pressKeyRepeatedly("KEY_VOLUP", count: target, spacing: 0.12,
                                    completion: completion)
        }
    }

    // MARK: - Connection state

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            log.info("Tizen socket ready; waiting for channel connect event")
        case .waiting(let error):
            log.debug("waiting: \(error)")
        case .failed(let error):
            log.error("connection failed: \(error)")
            finishConnect(false, "connection failed: \(error.localizedDescription)")
        case .cancelled:
            if connectCompletion != nil {
                finishConnect(false, "connection cancelled")
            }
        default:
            break
        }
    }

    /// Delivers the connect result exactly once and cleans up timers.
    private func finishConnect(_ ok: Bool, _ info: String?) {
        guard let completion = connectCompletion else { return }
        connectCompletion = nil
        stepTimer?.cancel()
        stepTimer = nil
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

    private func handleConnectionLost() {
        if connectCompletion != nil {
            finishConnect(false, "connection lost")
            return
        }
        if registered {
            log.warning("TV connection lost")
        }
        registered = false
        connection?.cancel()
        connection = nil
        setConnected(false)
    }

    private func setConnected(_ connected: Bool) {
        stateLock.lock()
        _isConnected = connected
        stateLock.unlock()
    }

    // MARK: - Registration

    private func sendRegistration() {
        guard connectCompletion != nil else { return }
        let data: [String: Any] = [
            "data": [["id": "remote.control.0", "token": currentToken]],
            "request": "host",
        ]
        let emit: [String: Any] = [
            "method": "ms.channel.emit",
            "params": ["event": "ms.remote.control", "data": data],
        ]
        // An invalid token always draws "ms.channel.unauthorized"; a valid one
        // may draw nothing on some firmware — treat silence as success.
        armStepTimer { [weak self] in
            guard let self else { return }
            if self.connectCompletion != nil, !self.registered {
                log.info("no registration reply; assuming authorized")
                self.registered = true
                self.finishConnect(true, self.currentToken.isEmpty ? nil : self.currentToken)
            }
        }
        if let connection {
            sendText(emit, on: connection) { [weak self] ok in
                guard let self else { return }
                if !ok {
                    self.finishConnect(false, "failed to send registration")
                }
            }
        } else {
            finishConnect(false, "no connection")
        }
    }

    private func handleUnauthorized(_ object: [String: Any]) {
        guard connectCompletion != nil else { return }
        // data[0].token carries the PIN the TV displays; it is informational
        // here (no UI in this controller). The user accepts the dialog on the
        // TV itself, after which "ms.channel.authorized" arrives.
        let pin = (object["data"] as? [[String: Any]])?.first?["token"] as? String
        log.info("pairing required — accept the dialog on the TV (PIN \(pin ?? "n/a", privacy: .private))")
        stepTimer?.cancel()
        stepTimer = nil
        let timer = DispatchWorkItem { [weak self] in
            self?.finishConnect(false, "pairing timed out — no authorization from the TV")
        }
        pairingTimer = timer
        queue.asyncAfter(deadline: .now() + pairingTimeout, execute: timer)
    }

    private func handleAuthorized(_ object: [String: Any]) {
        guard connectCompletion != nil else { return }
        let token = (object["data"] as? [[String: Any]])?.first?["token"] as? String ?? ""
        currentToken = token
        registered = true
        log.info("TV authorized remote control")
        finishConnect(true, token.isEmpty ? nil : token)
    }

    // MARK: - Messaging

    private func armStepTimer(_ action: @escaping () -> Void) {
        stepTimer?.cancel()
        let timer = DispatchWorkItem(block: action)
        stepTimer = timer
        queue.asyncAfter(deadline: .now() + stepTimeout, execute: timer)
    }

    private func sendText(_ object: [String: Any], on connection: NWConnection,
                          completion: ((Bool) -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            completion?(false)
            return
        }
        let context = NWConnection.ContentContext(
            identifier: "json",
            metadata: [NWProtocolWebSocket.Metadata(opcode: .text)]
        )
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            if let error {
                self?.log.error("send failed: \(error)")
                completion?(false)
            } else {
                completion?(true)
            }
        })
    }

    private func receiveLoop() {
        connection?.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.log.error("receive failed: \(error)")
                self.handleConnectionLost()
                return
            }
            if let data, !data.isEmpty {
                self.handleMessage(data)
            }
            if isComplete {
                self.handleConnectionLost()
                return
            }
            self.receiveLoop()
        }
    }

    private func handleMessage(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log.warning("non-JSON message from TV")
            return
        }
        guard let event = object["event"] as? String else { return }
        switch event {
        case "ms.channel.connect":
            if connectCompletion != nil, !registrationSent {
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
