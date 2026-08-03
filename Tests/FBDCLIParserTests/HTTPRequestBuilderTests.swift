import XCTest
@testable import FBDCLIParser

final class HTTPRequestBuilderTests: XCTestCase {
    private func request(
        method: String = "GET",
        path: String = "/api/displays",
        port: Int = 8765,
        body: [String: Any]? = nil,
        token: String = "test-token"
    ) -> URLRequest? {
        HTTPRequestBuilder.request(method: method, path: path, port: port, body: body, token: token)
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

    func testTokenHeaderAlwaysPresent() {
        XCTAssertEqual(request(token: "abc")?.value(forHTTPHeaderField: "X-FBD-Token"), "abc")
        XCTAssertEqual(request(method: "POST", body: [:], token: "xyz")?.value(forHTTPHeaderField: "X-FBD-Token"), "xyz")
    }

    func testTimeoutIsShort() {
        XCTAssertEqual(request()?.timeoutInterval, HTTPRequestBuilder.timeout)
        XCTAssertLessThan(HTTPRequestBuilder.timeout, 10)
    }
}
