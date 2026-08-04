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
/// All callbacks run on the shared serial queue (see
/// `WebSocketDisplayController`). Every completion is invoked exactly once;
/// each network step is bounded by a 5-second timeout.
public final class LGWebOSController: WebSocketDisplayController {
    private let handshakeTimeout: TimeInterval = 5
    private let requestTimeout: TimeInterval = 5
    private var clientKey: String?

    public init() {
        super.init(queue: DispatchQueue(label: "dev.fisifla.fbd.lgwebos"), logCategory: "LGWebOSController")
        wsSubprotocol = "luna-sublime"
    }

    // MARK: - Connect / disconnect

    /// Connect and run the handshake (hello → `ssap://api/deviceInfo`).
    /// On success, `completion(true, clientKey)` — persist `clientKey` and pass
    /// it back on the next `connect` call so pairing is not requested again.
    public func connect(host: String, port: UInt16 = 3000, clientKey: String?,
                        completion: @escaping (Bool, String?) -> Void) {
        self.clientKey = clientKey
        super.connect(host: host, port: port, completion: completion)
    }

    /// The whole handshake (TCP + WS upgrade + hello + deviceInfo) must finish
    /// within 5 seconds.
    override func didStartConnection() {
        let timer = DispatchWorkItem { [weak self] in
            self?.failInit("handshake timed out")
        }
        initTimer = timer
        queue.asyncAfter(deadline: .now() + handshakeTimeout, execute: timer)
    }

    /// The socket is up — start the "hello" handshake.
    override func onSocketReady() {
        sendHello()
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
                self.failInit("failed to send hello")
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
            failInit(reason)
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
                self.failInit("deviceInfo failed")
                return
            }
            self.initTimer?.cancel()
            self.initTimer = nil
            self.setConnected(true)
            self.log.info("handshake complete, client-key registered")
            if let completion = self.initCompletion {
                self.initCompletion = nil
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

    /// Messages carry a JSON-RPC id; the handshake response is id 0, other
    /// responses resolve the matching pending request. Notifications (no id)
    /// are ignored.
    override func handleMessage(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log.warning("non-JSON message from TV")
            return
        }
        guard let id = object["id"] as? Int else { return }

        if id == 0, initCompletion != nil {
            handleHandshakeResponse(object)
            return
        }
        if let callback = pending.removeValue(forKey: id) {
            callback(true, object)
        }
    }
}
