import Foundation
import os

/// Control for Philips Android TVs (jointSPACE JSON API, port 1926).
///
/// Endpoints (under the `/1/` jointSPACE version prefix used by Android-TV
/// models; pre-2017 jointSPACE 1.x models use the same paths without the
/// prefix — see the limitation note below):
///   POST /1/pair/request   — start pairing; the TV displays a 4-digit PIN
///   POST /1/pair/grant     — {"pin": "1234"} completes pairing
///   POST /1/audio/volume   — {"current": 0…100}
///   POST /1/power          — {"power": "on"} (only wakes from standby)
///   POST /1/input/key      — {"key": "WatchTV"|"Home"|"Source"|…} (key code)
///
/// Pairing flow (no UI lives in this controller — the caller owns it):
///   1. `pair(host:)` sends pair/request and completes `(true, nil)` once the
///      TV shows its PIN.
///   2. The caller shows the PIN-entry UI and calls `confirmPair(pin:)` with
///      the code the user typed.
///   3. `setVolume` / `powerOn` / `setInput` then work from the paired IP.
///
/// Auth note / limitation: jointSPACE normally uses HTTP digest auth on older
/// models. After a successful pair/grant the TV trusts the pairing IP, so plain
/// HTTP suffices on modern models. If a TV answers 401, enable the undocumented
/// "Simple IP" / joinAPI mode in the TV settings for unauthenticated access;
/// digest auth itself is deliberately not implemented here.
///
/// All callbacks run on a private serial queue; every request times out after
/// 5 seconds and each completion is called exactly once.
public final class PhilipsTVController {
    private let queue = DispatchQueue(label: "dev.fisifla.fbd.philips")
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "PhilipsTVController")
    private let session: URLSession

    /// TV host (IP or hostname). Set by `pair(host:)`, or directly for
    /// already-paired TVs. Required before control calls.
    public var host = ""

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Route every callback through the controller's serial queue.
        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = queue
        session = URLSession(configuration: config, delegate: nil, delegateQueue: operationQueue)
    }

    // MARK: - Pairing

    /// Start pairing: POST /pair/request. On success the TV shows a 4-digit PIN;
    /// call `confirmPair(pin:)` with what the user enters.
    public func pair(host: String, completion: @escaping (Bool, String?) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion(false, "controller deallocated")
                return
            }
            self.host = host
            self.post(path: "/1/pair/request",
                      json: ["scope": ["read", "write", "control"]]) { ok, error in
                completion(ok, ok ? nil : error)
            }
        }
    }

    /// Complete pairing with the PIN shown on the TV: POST /pair/grant.
    public func confirmPair(pin: String, completion: @escaping (Bool, String?) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion(false, "controller deallocated")
                return
            }
            let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                completion(false, "empty PIN")
                return
            }
            self.post(path: "/1/pair/grant", json: ["pin": trimmed]) { ok, error in
                completion(ok, ok ? nil : error)
            }
        }
    }

    // MARK: - Commands

    /// POST /audio/volume {"current": 0…100}.
    public func setVolume(_ volume: Int, completion: ((Bool) -> Void)? = nil) {
        post(path: "/1/audio/volume", json: ["current": min(max(volume, 0), 100)]) { ok, _ in
            completion?(ok)
        }
    }

    /// POST /power {"power": "on"} — only effective from standby.
    public func powerOn(completion: ((Bool) -> Void)? = nil) {
        post(path: "/1/power", json: ["power": "on"]) { ok, _ in
            completion?(ok)
        }
    }

    /// POST /input/key {"key": <key code>} (e.g. "WatchTV", "Home", "Source").
    /// Note: jointSPACE also offers /input/switch {"input": "HDMI 1"} for
    /// switching by input name; this controller follows the key-code form.
    public func setInput(_ input: String, completion: ((Bool) -> Void)? = nil) {
        post(path: "/1/input/key", json: ["key": input]) { ok, _ in
            completion?(ok)
        }
    }

    // MARK: - HTTP

    private func post(path: String, json: [String: Any],
                      completion: @escaping (Bool, String?) -> Void) {
        // Serialize host reads and requests on the controller's queue (host is
        // also written by pair()/confirmPair()).
        queue.async { [weak self] in
            guard let self else {
                completion(false, "controller deallocated")
                return
            }
            guard !self.host.isEmpty,
                  let url = URL(string: "http://\(self.displayHost(self.host)):1926\(path)") else {
                completion(false, "invalid host")
                return
            }
            guard let body = try? JSONSerialization.data(withJSONObject: json) else {
                completion(false, "failed to encode request")
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            self.session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else {
                    completion(false, "controller deallocated")
                    return
                }
                if let error {
                    self.log.error("POST \(path) failed: \(error.localizedDescription)")
                    completion(false, error.localizedDescription)
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    self.log.error("POST \(path) returned HTTP \(status)")
                    completion(false, "HTTP \(status)")
                    return
                }
                // jointSPACE replies {"error": null} on success; a non-null error
                // object means the request was refused (e.g. wrong PIN).
                if let data,
                   let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let error = object["error"], !(error is NSNull) {
                    let message = (error as? [String: Any])?["message"] as? String
                        ?? "request rejected"
                    self.log.error("POST \(path) rejected: \(message)")
                    completion(false, message)
                    return
                }
                completion(true, nil)
            }.resume()
        }
    }

    /// Brackets IPv6 literals so URL(string:) accepts them.
    private func displayHost(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }
}
