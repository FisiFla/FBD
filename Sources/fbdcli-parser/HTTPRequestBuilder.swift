import Foundation

/// Pure construction of the CLI's HTTP API requests (URL, method, JSON body,
/// signature header, timeout). Extracted from `fbdcli/HTTPAPIClient.swift` so the
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
        signature: (_ body: Data?) -> String
    ) -> URLRequest? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.timeoutInterval = timeout
        if let body {
            urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // Signed, never the token itself: the port comes from UserDefaults, so
        // this request may reach a listener that is not FBD. The signature
        // covers the body exactly as it is sent.
        urlRequest.setValue(signature(urlRequest.httpBody), forHTTPHeaderField: "X-FBD-Signature")
        return urlRequest
    }
}
