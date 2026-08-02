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
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    /// Cap request buffering so a local client cannot grow memory without bound.
    private static let maxRequestBytes = 1_048_576

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
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
                let contentLength = headerText
                    .split(separator: "\r\n")
                    .compactMap { line -> Int? in
                        let parts = line.split(separator: ":", maxSplits: 1)
                        guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                        return Int(parts[1].trimmingCharacters(in: .whitespaces))
                    }
                    .first ?? 0
                let receivedBody = accumulated.distance(from: headerRange.upperBound, to: accumulated.endIndex)
                if receivedBody >= contentLength || isComplete {
                    self.respond(connection, request: accumulated)
                    return
                }
            } else if isComplete {
                self.respond(connection, request: accumulated)
                return
            }
            self.receive(connection, buffer: accumulated)
        }
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
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 503: statusText = "Service Unavailable"
        default: statusText = "Error"
        }
        let response = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Headers: X-FBD-Token, Content-Type\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Content-Length: \(responseBody.utf8.count)\r
        Connection: close\r
        \r
        \(responseBody)
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
