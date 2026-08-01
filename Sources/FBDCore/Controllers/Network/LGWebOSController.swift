import Foundation
import Network
import os

/// Control for LG webOS TVs (2014+ models) over the WebSocket JSON-RPC "ssap://"
/// protocol (port 3000).
///
/// Wire protocol (per LG webOS TV API documentation):
///   ws://<host>:3000        — WebSocket, subprotocol "luna-sublime"
///   request:  {"id": n, "type": "request", "uri": "ssap://...", "payload": {...}}
///   response: {"id": n, "type": "response", "payload": {...}}
///
/// Handshake: a "hello" message first; the TV replies with the persisted
/// `client-key` (or an error if the key is not registered). Then
/// `ssap://api/deviceInfo` confirms the session is usable. The caller persists
/// the client key returned by `connect` and passes it back on reconnects so the
/// TV does not re-prompt for permission.
///
/// All callbacks run on a private serial queue. Every completion is invoked
/// exactly once; each network step is bounded by a 5-second timeout.
public final class LGWebOSController {
    private let queue = DispatchQueue(label: "dev.fisifla.fbd.lgwebos")
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "LGWebOSController")
    private let handshakeTimeout: TimeInterval = 5
    private let requestTimeout: TimeInterval = 5

    private var connection: NWConnection?
    private var nextRequestID = 1
    /// In-flight requests, keyed by JSON-RPC id.
    private var pending: [Int: (Bool, [String: Any]?) -> Void] = [:]
    private var handshakeCompletion: ((Bool, String?) -> Void)?
    private var handshakeTimer: DispatchWorkItem?
    private var clientKey: String?

    private let stateLock = NSLock()
    private var _isConnected = false

    public var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isConnected
    }

    public init() {}

    // MARK: - Connect / disconnect

    /// Connect and run the handshake (hello → `ssap://api/deviceInfo`).
    /// On success, `completion(true, clientKey)` — persist `clientKey` and pass
    /// it back on the next `connect` call so pairing is not requested again.
    public func connect(host: String, port: UInt16 = 3000, clientKey: String?,
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
            self.handshakeCompletion = completion
            self.clientKey = clientKey

            guard let port = NWEndpoint.Port(rawValue: port) else {
                self.failHandshake("invalid port")
                return
            }

            // WebSocket with the "luna-sublime" subprotocol webOS documents for
            // the TV API. NWParameters.ws already carries a WebSocket options
            // object — configure that one rather than stacking a second.
            var params = NWParameters.tcp
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            if let wsOptions = params.defaultProtocolStack.applicationProtocols.first
                as? NWProtocolWebSocket.Options {
                wsOptions.autoReplyPing = true
                wsOptions.setSubprotocols(["luna-sublime"])
            }

            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                self?.handleState(state)
            }
            connection.start(queue: self.queue)
            self.receiveLoop()

            // The whole handshake (TCP + WS upgrade + hello + deviceInfo) must
            // finish within 5 seconds.
            let timer = DispatchWorkItem { [weak self] in
                self?.failHandshake("handshake timed out")
            }
            self.handshakeTimer = timer
            self.queue.asyncAfter(deadline: .now() + self.handshakeTimeout, execute: timer)
        }
    }

    public func disconnect() {
        queue.async { [weak self] in
            self?.teardown()
        }
    }

    // MARK: - Commands

    /// Raw JSON-RPC send. `uri` is an "ssap://..." URI; the response payload is
    /// delivered to `completion` (or `(false, nil)` on timeout/error).
    public func send(uri: String, payload: [String: Any],
                     completion: ((Bool, [String: Any]?) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else {
                completion?(false, nil)
                return
            }
            guard self.isConnected, self.connection != nil else {
                completion?(false, nil)
                return
            }
            self.sendRequest(uri: uri, payload: payload, completion: completion)
        }
    }

    /// Power on the TV (`ssap://system/turnOn`). Note: works when the TV is in
    /// standby and reachable; a fully powered-off TV has no WebSocket server.
    public func powerOn(completion: ((Bool) -> Void)? = nil) {
        send(uri: "ssap://system/turnOn", payload: ["on": true]) { ok, _ in
            completion?(ok)
        }
    }

    public func setVolume(_ volume: Int, completion: ((Bool) -> Void)? = nil) {
        let clamped = min(max(volume, 0), 100)
        send(uri: "ssap://audio/setVolume", payload: ["volume": clamped]) { ok, _ in
            completion?(ok)
        }
    }

    public func setInput(_ input: String, completion: ((Bool) -> Void)? = nil) {
        send(uri: "ssap://tv/changeInput", payload: ["inputId": input]) { ok, _ in
            completion?(ok)
        }
    }

    // MARK: - Connection state

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            log.info("connected to webOS TV")
            sendHello()
        case .waiting(let error):
            log.debug("waiting: \(error)")
        case .failed(let error):
            log.error("connection failed: \(error)")
            if handshakeCompletion != nil {
                failHandshake("connection failed: \(error.localizedDescription)")
            } else {
                failPending("connection lost")
                connection?.cancel()
                connection = nil
                setConnected(false)
            }
        case .cancelled:
            if handshakeCompletion != nil {
                failHandshake("connection cancelled")
            }
        default:
            break
        }
    }

    /// Fails the pending handshake, cancels the socket, and reports exactly once.
    private func failHandshake(_ reason: String) {
        guard handshakeCompletion != nil else { return }
        handshakeTimer?.cancel()
        handshakeTimer = nil
        let completion = handshakeCompletion
        handshakeCompletion = nil
        connection?.cancel()
        connection = nil
        setConnected(false)
        completion?(false, reason)
    }

    private func failPending(_ reason: String) {
        guard !pending.isEmpty else { return }
        log.warning("failing \(self.pending.count) pending request(s): \(reason)")
        for (_, callback) in pending {
            callback(false, nil)
        }
        pending.removeAll()
    }

    private func teardown() {
        handshakeTimer?.cancel()
        handshakeTimer = nil
        if let completion = handshakeCompletion {
            handshakeCompletion = nil
            completion(false, "disconnected")
        }
        failPending("disconnected")
        connection?.cancel()
        connection = nil
        setConnected(false)
    }

    private func setConnected(_ connected: Bool) {
        stateLock.lock()
        _isConnected = connected
        stateLock.unlock()
    }

    // MARK: - Handshake

    private func sendHello() {
        let manifest: [String: Any] = [
            "appVersion": "1.0.0",
            "manifestVersion": 1,
            "permissions": ["LAUNCH", "APP_TO_APP"],
            "signed": [String: Any](),
        ]
        let hello: [String: Any] = [
            "id": 0,
            "type": "hello",
            "payload": ["client-key": clientKey ?? "", "manifest": manifest],
        ]
        sendText(hello) { [weak self] ok in
            guard let self else { return }
            if !ok {
                self.failHandshake("failed to send hello")
            }
        }
    }

    private func handleHandshakeResponse(_ object: [String: Any]) {
        let payload = object["payload"] as? [String: Any] ?? [:]
        guard payload["returnValue"] as? Bool ?? false else {
            let reason = payload["errorText"] as? String
                ?? payload["errorCode"] as? String
                ?? "registration rejected by TV"
            log.error("hello rejected: \(reason)")
            failHandshake(reason)
            return
        }

        // First pairing: the TV assigns a fresh client-key. When reconnecting
        // with a valid key it may echo it or omit it — keep the provided one.
        let grantedKey = (payload["client-key"] as? String) ?? clientKey ?? ""
        clientKey = grantedKey

        // Second handshake step: deviceInfo proves the session is usable.
        sendRequest(uri: "ssap://api/deviceInfo", payload: [:]) { [weak self] ok, _ in
            guard let self else { return }
            guard ok else {
                self.failHandshake("deviceInfo failed")
                return
            }
            self.handshakeTimer?.cancel()
            self.handshakeTimer = nil
            self.setConnected(true)
            log.info("handshake complete, client-key registered")
            if let completion = self.handshakeCompletion {
                self.handshakeCompletion = nil
                completion(true, grantedKey)
            }
        }
    }

    // MARK: - Messaging

    /// Sends a JSON-RPC request, tracking its id in `pending` with a timeout.
    /// Used by the public `send` and internally during the handshake.
    private func sendRequest(uri: String, payload: [String: Any],
                             completion: ((Bool, [String: Any]?) -> Void)?) {
        let id = nextRequestID
        nextRequestID += 1
        let request: [String: Any] = ["id": id, "type": "request", "uri": uri, "payload": payload]

        if completion != nil {
            pending[id] = completion
            queue.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
                guard let self else { return }
                if let callback = self.pending.removeValue(forKey: id) {
                    self.log.warning("request timed out: \(uri)")
                    callback(false, nil)
                }
            }
        }

        sendText(request) { [weak self] ok in
            guard let self else { return }
            if !ok, let callback = self.pending.removeValue(forKey: id) {
                callback(false, nil)
            }
        }
    }

    private func sendText(_ object: [String: Any], completion: ((Bool) -> Void)? = nil) {
        guard let connection else {
            completion?(false)
            return
        }
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
                // Close frame or EOF — the TV hung up.
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
        // Notifications (no id) are ignored.
        guard let id = object["id"] as? Int else { return }

        if id == 0, handshakeCompletion != nil {
            handleHandshakeResponse(object)
            return
        }
        if let callback = pending.removeValue(forKey: id) {
            callback(true, object)
        }
    }

    private func handleConnectionLost() {
        if handshakeCompletion != nil {
            failHandshake("connection lost during handshake")
        } else {
            failPending("connection lost")
            connection?.cancel()
            connection = nil
            setConnected(false)
        }
    }
}
