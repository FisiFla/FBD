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
    /// The request itself (URL/method/body/headers) is built by the tested
    /// HTTPRequestBuilder (FBDCLIParser); this function only executes it.
    private static func request(method: String, path: String, port: Int, body: [String: Any]?) -> (Int, Data)? {
        guard let urlRequest = HTTPRequestBuilder.request(
            method: method,
            path: path,
            port: port,
            body: body,
            token: Settings.httpAPIToken
        ) else { return nil }
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
