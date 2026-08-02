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

    /// True when the app's HTTP API answers on the published port.
    static func isAppRunning() -> Bool {
        guard let port = activePort() else { return false }
        guard let (status, _) = request(method: "GET", path: "/api/displays", port: port, body: nil) else {
            return false
        }
        return status == 200
    }

    static func get(_ path: String) -> (status: Int, data: Data)? {
        guard let port = activePort() else { return nil }
        return request(method: "GET", path: path, port: port, body: nil)
    }

    static func post(_ path: String, json: [String: Any]) -> (status: Int, data: Data)? {
        guard let port = activePort() else { return nil }
        return request(method: "POST", path: path, port: port, body: json)
    }

    static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Synchronous HTTP/1.1 request with a short timeout (CLI context).
    private static func request(method: String, path: String, port: Int, body: [String: Any]?) -> (Int, Data)? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.timeoutInterval = 3
        if let body {
            urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // The app's HTTP API requires the shared local token (same defaults
        // domain, so both sides read the same value).
        urlRequest.setValue(Settings.httpAPIToken, forHTTPHeaderField: "X-FBD-Token")
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Int, Data)?
        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                result = (http.statusCode, data ?? Data())
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        return result
    }
}
