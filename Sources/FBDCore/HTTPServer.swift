import Foundation
import Network
import os

private let log = Logger(subsystem: "dev.fisifla.fbd", category: "HTTPServer")

/// Minimal HTTP/1.1 server (NWListener) exposing the FBD control API.
/// Endpoints (JSON):
///   GET  /api/displays                — display list
///   GET  /api/displays/<id>           — display info
///   POST /api/displays/<id>/brightness {"value": 0…1}
///   POST /api/displays/<id>/volume    {"value": 0…1}
///   POST /api/displays/<id>/mute      {"muted": bool}
///   POST /api/displays/<id>/input     {"source": n}
///   POST /api/displays/<id>/mode      {"width": n, "height": n, "hz": n}
///   POST /api/displays/<id>/xdr       {"nits": n} | {"enabled": false}
///   POST /api/virtual/create          {"name": s, "width": n, "height": n, "hz": n}
///   POST /api/virtual/destroy         {"id": s}
public final class HTTPServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.fisifla.fbd.http")
    private var handler: ((String, String, String?, [String: String]) -> (Int, String))?
    /// Requested port (0 = ephemeral); used until the listener reports its port.
    private var requestedPort: UInt16 = 0

    /// Connections that send no data for this long are dropped (idle
    /// resource hygiene — a local client can otherwise hold a connection
    /// forever).
    public var idleTimeout: TimeInterval = 10

    /// True while a listener is active. start() is restart-safe: calling it
    /// while running stops the previous listener first.
    public private(set) var isRunning = false

    /// Per-connection bookkeeping (thread-confined to `queue`).
    private final class ConnectionState {
        var sentContinue = false
        var idleWorkItem: DispatchWorkItem?
    }

    public var port: UInt16 { listener?.port?.rawValue ?? requestedPort }

    public init() {}

    /// Start listening on 127.0.0.1. `handler(requestMethod, requestPath, requestBody, requestHeaders) -> (statusCode, responseBody)`.
    /// `onReady` is invoked once the listener is ready (immediately for fixed
    /// ports; after binding for ephemeral port 0) with the actual port.
    @discardableResult
    public func start(
        port: UInt16 = 0,
        handler: @escaping (String, String, String?, [String: String]) -> (Int, String),
        onReady: ((UInt16) -> Void)? = nil
    ) -> Bool {
        self.handler = handler
        requestedPort = port
        // Restart-safe: replace any existing listener (port changes).
        if isRunning {
            stop()
        }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? 0)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    onReady?(listener.port?.rawValue ?? port)
                case .failed(let error):
                    log.error("listener failed: \(error)")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            isRunning = true
            log.info("HTTP server listening on 127.0.0.1:\(listener.port?.rawValue ?? 0)")
            return true
        } catch {
            log.error("HTTP server start failed: \(error)")
            return false
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        let state = ConnectionState()
        connection.stateUpdateHandler = { [weak state] newState in
            if case .cancelled = newState {
                state?.idleWorkItem?.cancel()
            }
        }
        connection.start(queue: queue)
        scheduleIdleTimeout(connection, state: state)
        receive(connection, buffer: Data(), state: state)
    }

    /// Reset the idle timer: the connection is dropped when no data arrives
    /// within `idleTimeout`.
    private func scheduleIdleTimeout(_ connection: NWConnection, state: ConnectionState) {
        state.idleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak connection] in
            connection?.cancel()
        }
        state.idleWorkItem = work
        queue.asyncAfter(deadline: .now() + idleTimeout, execute: work)
    }

    /// Cap request buffering so a local client cannot grow memory without bound.
    private static let maxRequestBytes = 1_048_576

    private func receive(_ connection: NWConnection, buffer: Data, state: ConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if data != nil {
                // Data arrived: keep the connection alive.
                self.scheduleIdleTimeout(connection, state: state)
            }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }
            if let error {
                log.debug("connection error: \(error)")
                connection.cancel()
                return
            }
            if accumulated.count > Self.maxRequestBytes {
                log.warning("request too large — closing connection")
                connection.cancel()
                return
            }
            // Headers and body can arrive in separate TCP segments: only
            // respond once the full Content-Length body has been received.
            if let headerRange = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let headerText = String(data: accumulated[..<headerRange.lowerBound], encoding: .utf8) ?? ""
                let head = parseHead(headerText)
                let receivedBody = accumulated.distance(from: headerRange.upperBound, to: accumulated.endIndex)
                let bodyComplete = receivedBody >= head.contentLength || isComplete

                // Reject declared-oversized bodies immediately instead of
                // buffering toward the cap (memory + slow-loris hygiene).
                if head.contentLength > Self.maxRequestBytes {
                    log.warning("declared Content-Length \(head.contentLength) exceeds limit")
                    sendResponse(connection, status: 413, body: #"{"error":"payload too large"}"#)
                    return
                }

                // Honor Expect: 100-continue so clients send the body (curl
                // and URLSession otherwise wait for the interim response).
                if !state.sentContinue, !bodyComplete,
                   head.headers["expect"]?.lowercased() == "100-continue" {
                    connection.send(
                        content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8),
                        completion: .contentProcessed { _ in
                            state.sentContinue = true
                            self.receive(connection, buffer: accumulated, state: state)
                        }
                    )
                    return
                }

                if bodyComplete {
                    self.respond(connection, request: accumulated)
                    return
                }
            } else if isComplete {
                self.respond(connection, request: accumulated)
                return
            }
            self.receive(connection, buffer: accumulated, state: state)
        }
    }

    /// Parsed request head: lowercased header names + declared body length.
    private struct RequestHead {
        let headers: [String: String]
        let contentLength: Int
    }

    private func parseHead(_ headerText: String) -> RequestHead {
        var headers: [String: String] = [:]
        var contentLength = 0
        for line in headerText.split(separator: "\r\n").dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let name = String(pair[0]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(pair[1]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
            if name == "content-length" {
                contentLength = Int(value) ?? 0
            }
        }
        return RequestHead(headers: headers, contentLength: contentLength)
    }

    private func respond(_ connection: NWConnection, request: Data) {
        guard let requestText = String(data: request, encoding: .utf8) else {
            connection.cancel()
            return
        }
        let lines = requestText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }
        let method = String(parts[0])
        var path = String(parts[1])
        var body: String?
        var headers: [String: String] = [:]
        if let headerEnd = requestText.range(of: "\r\n\r\n") {
            let bodyText = requestText[headerEnd.upperBound...]
            if !bodyText.isEmpty { body = String(bodyText) }
            // Header lines: "Name: value" (lowercased names).
            for line in requestText[..<headerEnd.lowerBound].split(separator: "\r\n").dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1)
                if pair.count == 2 {
                    headers[String(pair[0]).trimmingCharacters(in: .whitespaces).lowercased()] =
                        String(pair[1]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        // Strip query string.
        if let q = path.firstIndex(of: "?") {
            path = String(path[..<q])
        }

        // CORS preflight for web-based clients (local API; the token header
        // is still required on all real requests).
        if method == "OPTIONS" {
            connection.send(content: Data(Self.corsResponse().utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let started = Date()
        let (status, responseBody) = handler?(method, path, body, headers) ?? (404, #"{"error":"not found"}"#)
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
        log.debug("\(method) \(path) -> \(status) (\(latencyMs) ms)")
        sendResponse(connection, status: status, body: responseBody)
    }

    /// Write a complete JSON response and close the connection.
    private func sendResponse(_ connection: NWConnection, status: Int, body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 413: statusText = "Payload Too Large"
        case 503: statusText = "Service Unavailable"
        default: statusText = "Error"
        }
        let response = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Headers: X-FBD-Token, Content-Type\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// 204 response for CORS preflight (no handler invocation).
    private static func corsResponse() -> String {
        """
        HTTP/1.1 204 No Content\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Headers: X-FBD-Token, Content-Type\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Content-Length: 0\r
        Connection: close\r
        \r
        """
    }
}
