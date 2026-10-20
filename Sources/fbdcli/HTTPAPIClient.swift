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

    /// One state-changing exchange: what the CLI knows about the write, and
    /// the body the app sent back (empty when no reply arrived).
    struct WriteResponse {
        /// `applied`, `refused`, `failed` or `replyLost`.
        let outcome: WriteOutcome
        /// The response body, empty when there was no response.
        let body: Data
    }

    /// Result of one HTTP exchange.
    private enum Outcome {
        case response(Int, Data)
        /// Nothing is listening on the published port.
        case refused
        case timedOut
        /// The connection broke after the request went out.
        case failed(String)
        /// The request never left the CLI.
        case notSent(String)
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
        case .notSent(let message): return .unresponsive(message)
        }
    }

    static func get(_ path: String) -> (status: Int, data: Data)? {
        guard let port = activePort() else { return nil }
        switch request(method: "GET", path: path, port: port, body: nil) {
        case .response(let status, let data): return (status, data)
        case .refused, .timedOut, .failed, .notSent: return nil
        }
    }

    /// Send a state-changing request.
    ///
    /// The result says what the CLI *knows*, not what it hopes: a lost reply
    /// is reported as `replyLost`, because the app may have committed the
    /// write before the answer went missing. The caller turns that into the
    /// CLI's write-failure wording (which names the read-back command)
    /// instead of inviting a blind retry.
    static func post(_ path: String, json: [String: Any]) -> WriteResponse {
        guard let port = activePort() else {
            return WriteResponse(outcome: .failed(reason: "the app is not listening"), body: Data())
        }
        switch request(method: "POST", path: path, port: port, body: json) {
        case .response(let status, let data):
            let outcome: WriteOutcome = (200...299).contains(status)
                ? .applied
                : .refused(status: status)
            return WriteResponse(outcome: outcome, body: data)
        case .timedOut:
            return WriteResponse(
                outcome: .replyLost(reason: "the app did not answer in time"),
                body: Data()
            )
        case .failed(let message):
            return WriteResponse(
                outcome: .replyLost(reason: "the connection broke before the reply arrived (\(message))"),
                body: Data()
            )
        case .refused:
            return WriteResponse(
                outcome: .failed(reason: "the app refused the connection"),
                body: Data()
            )
        case .notSent(let message):
            return WriteResponse(outcome: .failed(reason: message), body: Data())
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
        ) else { return .notSent("the request could not be built") }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Outcome = .timedOut
        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            if let http = response as? HTTPURLResponse {
                outcome = .response(http.statusCode, data ?? Data())
            } else if let urlError = error as? URLError {
                switch urlError.code {
                // Nothing was listening: the request never went out.
                case .cannotConnectToHost, .cannotFindHost: outcome = .refused
                // The request went out; the answer did not come back.
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
