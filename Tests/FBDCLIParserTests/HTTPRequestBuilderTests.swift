import XCTest
@testable import FBDCLIParser
import FBDCore

final class HTTPRequestBuilderTests: XCTestCase {
    private func request(
        method: String = "GET",
        path: String = "/api/displays",
        port: Int = 8765,
        body: [String: Any]? = nil,
        token: String = "test-token",
        now: Date = Date()
    ) -> URLRequest? {
        HTTPRequestBuilder.request(method: method, path: path, port: port, body: body) {
            APIToken.signature(token: token, method: method, path: path, body: $0, now: now)
        }
    }

    func testBuildsLocalhostURLWithPortAndPath() {
        let request = request()
        XCTAssertEqual(request?.url?.absoluteString, "http://127.0.0.1:8765/api/displays")
        XCTAssertEqual(request?.httpMethod, "GET")
    }

    func testMethodAndPathPassThrough() {
        let request = request(method: "POST", path: "/api/displays/1/brightness")
        XCTAssertEqual(request?.url?.absoluteString, "http://127.0.0.1:8765/api/displays/1/brightness")
        XCTAssertEqual(request?.httpMethod, "POST")
    }

    func testJSONBodyAndContentType() throws {
        let request = request(method: "POST", body: ["value": 0.6])
        let body = try XCTUnwrap(request?.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["value"] as? Double, 0.6)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testNoBodyMeansNoContentType() {
        let request = request()
        XCTAssertNil(request?.httpBody)
        XCTAssertNil(request?.value(forHTTPHeaderField: "Content-Type"))
    }

    func testTheTokenItselfIsNeverSent() {
        for request in [request(token: "abc"), request(method: "POST", body: ["value": 0.6], token: "abc")] {
            XCTAssertNil(request?.value(forHTTPHeaderField: "X-FBD-Token"))
            XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
            let signature = request?.value(forHTTPHeaderField: "X-FBD-Signature") ?? ""
            XCTAssertTrue(signature.hasPrefix("v1:"))
            XCTAssertFalse(signature.contains("abc"))
        }
    }

    /// The contract that matters: what the CLI builds is what the app's router
    /// accepts, body and all — and nothing else is.
    func testSignedRequestIsAcceptedByTheRouter() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let request = try XCTUnwrap(
            request(method: "POST", path: "/api/displays/1/brightness", body: ["value": 0.6], token: "tok", now: now)
        )
        let signature = try XCTUnwrap(request.value(forHTTPHeaderField: "X-FBD-Signature"))
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })

        func route(path: String = "/api/displays/1/brightness", body: String, token: String = "tok", at date: Date) -> HTTPRouteResult {
            HTTPRouter.route(
                method: "POST", path: path, body: body,
                headers: ["x-fbd-signature": signature], expectedToken: token, now: date
            )
        }
        let unauthorized = HTTPRouteResult.error(status: 401, message: "unauthorized")
        XCTAssertNotEqual(route(body: body, at: now), unauthorized)
        XCTAssertNotEqual(route(body: body, at: now.addingTimeInterval(20)), unauthorized)
        XCTAssertEqual(route(body: body, at: now.addingTimeInterval(60)), unauthorized, "stale")
        XCTAssertEqual(route(body: body, at: now.addingTimeInterval(-60)), unauthorized, "from the future")
        XCTAssertEqual(route(body: #"{"value":1}"#, at: now), unauthorized, "another body")
        XCTAssertEqual(route(path: "/api/displays/2/brightness", body: body, at: now), unauthorized, "another path")
        XCTAssertEqual(route(body: body, token: "other", at: now), unauthorized, "another token")
        XCTAssertEqual(route(body: body, token: "", at: now), unauthorized, "no token available")
    }

    func testTimeoutIsShort() {
        XCTAssertEqual(request()?.timeoutInterval, HTTPRequestBuilder.timeout)
        XCTAssertLessThan(HTTPRequestBuilder.timeout, 10)
    }
}
