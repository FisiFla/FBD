import CryptoKit
import Foundation

/// The local control-API token: comparison and user-facing guidance.
///
/// The token itself lives in the Keychain (`Settings.httpAPIToken`); this
/// type owns everything *around* it, so the HTTP router, the `fbd://` URL
/// handler and the CLI share one implementation instead of three copies.
public enum APIToken {
    /// Constant-time-ish token comparison: hashing both sides first makes
    /// the comparison independent of token length and prefix content, so a
    /// local attacker timing the endpoint learns nothing usable about the
    /// token (the digest `==` leaks at most an irrelevant digest byte).
    ///
    /// Fails closed: an absent or empty provided token never matches, even
    /// when the expected token is also empty (an unavailable token must
    /// reject every request, not accept them).
    public static func matches(_ provided: String?, _ expected: String) -> Bool {
        guard let provided, !provided.isEmpty, !expected.isEmpty else { return false }
        let providedDigest = SHA256.hash(data: Data(provided.utf8))
        let expectedDigest = SHA256.hash(data: Data(expected.utf8))
        return providedDigest == expectedDigest
    }

    /// How far a signed request's timestamp may be from now, in seconds.
    public static let signatureWindow: TimeInterval = 30

    /// `X-FBD-Signature` value for one request: proof of knowing the token
    /// that does not contain it.
    ///
    /// `fbdcli` authenticates this way because it finds the app through a
    /// port number in UserDefaults, and whatever is listening there gets the
    /// request. A bearer token sent to the wrong listener is lost for good; a
    /// signature is good for this one request, for `signatureWindow` seconds.
    ///
    /// `v1:<unix seconds>:<base64 HMAC-SHA256>` over the version, timestamp,
    /// method, path and a SHA-256 of the body, keyed with the token.
    public static func signature(
        token: String,
        method: String,
        path: String,
        body: Data?,
        now: Date = Date()
    ) -> String {
        let timestamp = Int(now.timeIntervalSince1970)
        return "v1:\(timestamp):\(mac(token: token, timestamp: timestamp, method: method, path: path, body: body))"
    }

    /// Whether `signature` was made with `expected` for exactly this request,
    /// within `signatureWindow` of `now`. Fails closed like `matches`: an
    /// absent signature or an empty token never passes.
    public static func signatureMatches(
        _ signature: String?,
        _ expected: String,
        method: String,
        path: String,
        body: Data?,
        now: Date = Date()
    ) -> Bool {
        guard let signature, !expected.isEmpty else { return false }
        let parts = signature.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v1", let timestamp = Int(parts[1]),
              abs(now.timeIntervalSince1970 - TimeInterval(timestamp)) <= signatureWindow else {
            return false
        }
        // Compared through `matches`, so timing says nothing about the MAC.
        return matches(
            String(parts[2]),
            mac(token: expected, timestamp: timestamp, method: method, path: path, body: body)
        )
    }

    private static func mac(token: String, timestamp: Int, method: String, path: String, body: Data?) -> String {
        let bodyDigest = SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined()
        let message = "v1\n\(timestamp)\n\(method)\n\(path)\n\(bodyDigest)"
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data(token.utf8))
        )
        return Data(code).base64EncodedString()
    }

    /// Guidance printed instead of the token itself. The token grants full
    /// control of the user's displays, so `fbdcli auth-token` must not put
    /// it on stdout by default — only `--reveal` does that.
    public static let revealInstructions = """
    The local HTTP API token is a secret: it grants full control of your displays.
    It is not printed by default.

      fbdcli auth-token --reveal    print the token (pipe it; do not paste it into chats)

    The token is generated on first use and stored in the login keychain
    (service "dev.fisifla.fbd", account "httpAPIToken").

    Send it with a request as either header:

      curl -H "x-fbd-token: $TOKEN" http://127.0.0.1:<port>/api/displays
      curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:<port>/api/displays
    """
}
