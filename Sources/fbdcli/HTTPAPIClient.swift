import FBDCLIParser
import FBDCore
import Foundation

/// Routes CLI commands through the app's local HTTP API when FBD.app is
/// running. Single-driver principle: all DDC/I2C writes go through the app so
/// the CLI never contends with it on the hardware bus. Falls back to direct
/// controllers when the app is not running.
enum HTTPAPIClient {
    /// The port FBD.app published after starting its server (0 = not running).
    static func activePort() -> Int? {
        let port = Settings.httpServerActivePort
        guard port > 0, port < 65536 else { return nil }
        return port
    }

    /// What `probe()` found. Only `.notRunning` permits falling back to direct
    /// hardware control; any other failure means the app owns the bus and the
    /// CLI must not contend with it.
    enum AppProbe {
        case notRunning
        case running
        case unauthorized
        case unresponsive(String)
    }

    /// Result of one HTTP exchange.
    private enum Outcome {
        case response(Int, Data)
        /// Nothing is listening on the published port.
        case refused
        case timedOut
        case failed(String)
    }

    /// Distinguishes "app not listening" (safe to drive hardware directly)
    /// from "app up but erroring, slow or rejecting our token" (not safe).
    static func probe() -> AppProbe {
        guard let port = activePort() else { return .notRunning }
        switch request(method: "GET", path: "/api/displays", port: port, body: nil) {
        case .response(200, _): return .running
        case .response(401, _), .response(403, _): return .unauthorized
        case .response(let status, _): return .unresponsive("HTTP \(status)")
        case .refused: return .notRunning
        case .timedOut: return .unresponsive("request timed out")
        case .failed(let message): return .unresponsive(message)
        }
    }

    static func get(_ path: String) -> (status: Int, data: Data)? {
        guard let port = activePort() else { return nil }
        return unwrap(request(method: "GET", path: path, port: port, body: nil), mutating: false)
    }

    static func post(_ path: String, json: [String: Any]) -> (status: Int, data: Data)? {
        guard let port = activePort() else { return nil }
        return unwrap(request(method: "POST", path: path, port: port, body: json), mutating: true)
    }

    /// Callers never fall back to direct control after a routed request, so a
    /// nil here is reported, not retried. A timed-out write is called out
    /// explicitly: the app may still apply it.
    private static func unwrap(_ outcome: Outcome, mutating: Bool) -> (status: Int, data: Data)? {
        switch outcome {
        case .response(let status, let data):
            return (status, data)
        case .timedOut:
            if mutating {
                fputs("fbdcli: the app did not answer in time; the change may still be applied (not retrying directly)\n", stderr)
            }
            return nil
        case .refused, .failed:
            return nil
        }
    }

    static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Synchronous HTTP/1.1 request with a short timeout (CLI context).
    /// The request itself (URL/method/body/headers) is built by the tested
    /// HTTPRequestBuilder (FBDCLIParser); this function only executes it.
    private static func request(method: String, path: String, port: Int, body: [String: Any]?) -> Outcome {
        guard let urlRequest = HTTPRequestBuilder.request(
            method: method,
            path: path,
            port: port,
            body: body,
            token: Settings.httpAPIToken
        ) else { return .failed("could not build request") }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Outcome = .timedOut
        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            if let http = response as? HTTPURLResponse {
                outcome = .response(http.statusCode, data ?? Data())
            } else if let urlError = error as? URLError {
                switch urlError.code {
                case .cannotConnectToHost: outcome = .refused
                case .timedOut: outcome = .timedOut
                default: outcome = .failed(urlError.localizedDescription)
                }
            } else {
                outcome = .failed(error?.localizedDescription ?? "no response")
            }
            semaphore.signal()
        }
        task.resume()
        // Wait just past the URLSession timeout so URLSession reports its own
        // .timedOut error instead of this wait racing it.
        if semaphore.wait(timeout: .now() + urlRequest.timeoutInterval + 1) == .timedOut {
            task.cancel()
            return .timedOut
        }
        return outcome
    }
}
