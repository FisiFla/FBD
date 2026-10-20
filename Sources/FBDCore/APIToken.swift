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
