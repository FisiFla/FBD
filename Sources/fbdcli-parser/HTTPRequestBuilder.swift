import Foundation

/// Pure construction of the CLI's HTTP API requests (URL, method, JSON body,
/// auth header, timeout). Extracted from `fbdcli/HTTPAPIClient.swift` so the
/// wire contract is unit-tested without a server.
public enum HTTPRequestBuilder {
    /// Timeout for CLI requests (seconds).
    public static let timeout: TimeInterval = 3

    /// Build the request the CLI sends to FBD.app's local API.
    /// Returns nil only when the URL cannot be constructed.
    public static func request(
        method: String,
        path: String,
        port: Int,
        body: [String: Any]?,
        token: String
    ) -> URLRequest? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.timeoutInterval = timeout
        if let body {
            urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // The app's HTTP API requires the shared local token (same defaults
        // domain, so both sides read the same value).
        urlRequest.setValue(token, forHTTPHeaderField: "X-FBD-Token")
        return urlRequest
    }
}
