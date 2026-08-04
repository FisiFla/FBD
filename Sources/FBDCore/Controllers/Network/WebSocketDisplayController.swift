import Foundation
import Network
import os

/// Shared WebSocket connection machinery for the display-network controllers
/// (LG webOS, Samsung Tizen). Both speak JSON over a `ws://` socket with the
/// same lifecycle — connect, protocol-specific handshake, receive loop,
/// connection-lost teardown — so the socket plumbing lives here once.
///
/// Subclasses supply the protocol via `makeURL(host:port:)`,
/// `onSocketReady()`, and `handleMessage(_:)`; the base owns the connection,
/// the receive loop, the init-completion (reported exactly once), pending
/// request tracking, and the teardown paths.
/// The base is public because both subclasses are public (they are used from
/// the CLI); its members stay internal — subclasses live in the same module.
public class WebSocketDisplayController {
    let queue: DispatchQueue
    let log: Logger
    let stateLock = NSLock()
    private var _isConnected = false
    /// Internal setter so subclasses can tear down on their protocol paths.
    var connection: NWConnection?

    /// Initialization completion (LG handshake / Tizen channel connect). The
    /// base fails it exactly once when the connection dies mid-handshake.
    var initCompletion: ((Bool, String?) -> Void)?
    /// Timer guarding the handshake, if the subclass arms one.
    var initTimer: DispatchWorkItem?
    /// Optional WebSocket subprotocol (LG: "luna-sublime"; Tizen: none).
    var wsSubprotocol: String?

    /// Pending request-id callbacks (LG-style request/response; unused by
    /// event-only protocols like Tizen).
    var pending: [Int: (Bool, [String: Any]?) -> Void] = [:]
    var nextRequestID = 1

    public init(queue: DispatchQueue, logCategory: String) {
        self.queue = queue
        self.log = Logger(subsystem: "dev.fisifla.fbd", category: logCategory)
    }

    public var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isConnected
    }

    // MARK: - Connect / disconnect

    /// Opens the WebSocket. The subclass's `makeURL` builds the endpoint (the
    /// two protocols differ in path); `completion` receives the handshake
    /// result exactly once. Subclasses may arm an init timer by overriding
    /// `didStartConnection()`.
    public func connect(host: String, port: UInt16, completion: @escaping (Bool, String?) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion(false, "controller deallocated")
                return
            }
            guard self.connection == nil else {
                completion(false, "already connected or connecting")
                return
            }
            self.initCompletion = completion
            guard let port = NWEndpoint.Port(rawValue: port),
                  let url = self.makeURL(host: host, port: port.rawValue) else {
                self.failInit("invalid host or port")
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
                if let subprotocol = self.wsSubprotocol {
                    existing.setSubprotocols([subprotocol])
                }
            }

            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                self?.handleState(state)
            }
            connection.start(queue: self.queue)
            self.receiveLoop()
            self.didStartConnection()
        }
    }

    public func disconnect() {
        queue.async { [weak self] in
            self?.teardown()
        }
    }

    /// Hook: called after the socket starts; arm handshake timers here.
    func didStartConnection() {}

    /// Hook: build the protocol-specific endpoint URL.
    func makeURL(host: String, port: UInt16) -> URL? {
        URL(string: "ws://\(NetworkHost.bracketed(host)):\(port)")
    }

    // MARK: - Sending

    /// Send a JSON object as a WebSocket text frame.
    func sendText(_ object: [String: Any], completion: ((Bool) -> Void)? = nil) {
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

    // MARK: - Receive loop

    /// Recursively reads the next message until the socket closes. This loop
    /// is identical for both protocols; `handleMessage` is the subclass hook.
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

    /// Subclass hook: parse one protocol message.
    func handleMessage(_ data: Data) {}

    // MARK: - Connection state

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            log.info("socket ready")
            onSocketReady()
        case .waiting(let error):
            log.debug("waiting: \(error)")
        case .failed(let error):
            log.error("connection failed: \(error)")
            if initCompletion != nil {
                failInit("connection failed: \(error.localizedDescription)")
            } else {
                handleConnectionLost()
            }
        case .cancelled:
            if initCompletion != nil {
                failInit("connection cancelled")
            }
        default:
            break
        }
    }

    /// Hook: the socket is up; start the protocol handshake.
    func onSocketReady() {}

    /// Fails the pending handshake, cancels the socket, and reports exactly once.
    func failInit(_ reason: String) {
        guard initCompletion != nil else { return }
        initTimer?.cancel()
        initTimer = nil
        let completion = initCompletion
        initCompletion = nil
        connection?.cancel()
        connection = nil
        setConnected(false)
        completion?(false, reason)
    }

    func failPending(_ reason: String) {
        guard !pending.isEmpty else { return }
        log.warning("failing \(self.pending.count) pending request(s): \(reason)")
        for (_, callback) in pending {
            callback(false, nil)
        }
        pending.removeAll()
    }

    func handleConnectionLost() {
        if initCompletion != nil {
            failInit("connection lost during handshake")
            return
        }
        failPending("connection lost")
        connection?.cancel()
        connection = nil
        setConnected(false)
    }

    func teardown() {
        initTimer?.cancel()
        initTimer = nil
        if let completion = initCompletion {
            initCompletion = nil
            completion(false, "disconnected")
        }
        failPending("disconnected")
        connection?.cancel()
        connection = nil
        setConnected(false)
    }

    func setConnected(_ connected: Bool) {
        stateLock.lock()
        _isConnected = connected
        stateLock.unlock()
    }
}
