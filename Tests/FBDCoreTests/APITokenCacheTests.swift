import XCTest
@testable import FBDCore

/// The HTTP API token must never be read on the main actor: a Keychain access
/// prompt blocks until the user answers it, and on the main actor that freezes
/// the whole app. `APITokenCache` is the seam that keeps the read off the main
/// actor and out of the request path.
final class APITokenCacheTests: XCTestCase {
    func testTheTokenIsReadOnlyOnce() {
        var reads = 0
        let cache = APITokenCache { reads += 1; return "token" }

        XCTAssertEqual(cache.resolve(), "token")
        XCTAssertEqual(cache.resolve(), "token")
        XCTAssertEqual(reads, 1, "the Keychain must not be read again once the token is cached")
    }

    func testPeekNeverReadsTheKeychain() {
        var reads = 0
        let cache = APITokenCache { reads += 1; return "token" }

        XCTAssertNil(cache.peek(), "nothing is resolved before the first resolve")
        XCTAssertEqual(reads, 0, "peek must not touch the Keychain")

        _ = cache.resolve()
        XCTAssertEqual(cache.peek(), "token")
        XCTAssertEqual(reads, 1)
    }

    func testPeekStaysNilWhenTheTokenIsUnreadable() {
        let cache = APITokenCache { "" }
        XCTAssertEqual(cache.resolve(), "", "an empty token is still a resolved value")
        XCTAssertEqual(cache.peek(), "")
    }

    func testInvalidateForcesAFreshRead() {
        var reads = 0
        let cache = APITokenCache { reads += 1; return "token-\(reads)" }

        XCTAssertEqual(cache.resolve(), "token-1")
        XCTAssertEqual(cache.resolve(), "token-1")
        cache.invalidate()
        XCTAssertEqual(cache.resolve(), "token-2", "an invalidated cache reads the Keychain again")
        XCTAssertEqual(reads, 2)
    }

    func testConcurrentResolvesReadTheKeychainOnlyOnce() {
        var reads = 0
        let lock = NSLock()
        let cache = APITokenCache {
            lock.lock()
            reads += 1
            lock.unlock()
            return "token"
        }

        let group = DispatchGroup()
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) {
                XCTAssertEqual(cache.resolve(), "token")
            }
        }
        group.wait()

        XCTAssertEqual(reads, 1, "a Keychain prompt must never be raised twice at once")
    }
}
