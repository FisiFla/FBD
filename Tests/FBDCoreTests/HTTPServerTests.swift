import XCTest
import FBDCore

/// Round-trip tests for the hand-rolled HTTP server (ephemeral port,
/// stub handler — no app state involved).
final class HTTPServerTests: XCTestCase {
    private var server: HTTPServer!
    private var received: [(method: String, path: String, body: String?)] = []
    private var queue = DispatchQueue(label: "test.http")

    override func setUp() {
        super.setUp()
        received = []
    }

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    /// Start a server with a stub handler that records requests and echoes
    /// a JSON payload. Returns the bound port.
    @discardableResult
    private func startServer(port: UInt16 = 0) -> UInt16 {
        let server = HTTPServer()
        let ready = expectation(description: "listener ready")
        var boundPort: UInt16 = 0
        let started = server.start(port: port) { [weak self] method, path, body in
            self?.queue.sync {
                self?.received.append((method, path, body))
            }
            let body = body ?? "null"
            return (200, #"{"ok":true,"echo":\#(body)}"#)
        } onReady: { actualPort in
            boundPort = actualPort
            ready.fulfill()
        }
        XCTAssertTrue(started)
        self.server = server
        wait(for: [ready], timeout: 5)
        XCTAssertNotEqual(boundPort, 0)
        return boundPort
    }

    private func get(_ port: UInt16, _ path: String, timeout: TimeInterval = 5) -> (status: Int, body: Data)? {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        let expectation = expectation(description: "GET \(path)")
        var result: (Int, Data)?
        URLSession.shared.dataTask(with: url) { data, response, _ in
            if let data, let http = response as? HTTPURLResponse {
                result = (http.statusCode, data)
            }
            expectation.fulfill()
        }.resume()
        wait(for: [expectation], timeout: timeout)
        return result
    }

    private func post(_ port: UInt16, _ path: String, body: String, timeout: TimeInterval = 5) -> (status: Int, body: Data)? {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        let expectation = expectation(description: "POST \(path)")
        var result: (Int, Data)?
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let http = response as? HTTPURLResponse {
                result = (http.statusCode, data)
            }
            expectation.fulfill()
        }.resume()
        wait(for: [expectation], timeout: timeout)
        return result
    }

    // MARK: - Round trips

    func testGETRoundTrip() throws {
        let port = startServer()

        let result = try XCTUnwrap(get(port, "/api/displays"))

        XCTAssertEqual(result.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].method, "GET")
        XCTAssertEqual(received[0].path, "/api/displays")
        XCTAssertNil(received[0].body)
    }

    func testPOSTRoundTripDeliversJSONBody() throws {
        let port = startServer()

        let result = try XCTUnwrap(post(port, "/api/displays/1/brightness", body: #"{"value":0.55}"#))

        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].method, "POST")
        XCTAssertEqual(received[0].path, "/api/displays/1/brightness")
        XCTAssertEqual(received[0].body, #"{"value":0.55}"#)
        // Response echoes the request body as JSON.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        XCTAssertEqual((json["echo"] as? [String: Any])?["value"] as? Double, 0.55)
    }

    func testQueryStringIsStrippedFromPath() throws {
        let port = startServer()

        _ = get(port, "/api/displays?verbose=1")

        XCTAssertEqual(received.first?.path, "/api/displays")
    }

    func testHandlerStatusAndTextArePassedThrough() throws {
        // Stub handler returning 405 with a JSON body.
        let server = HTTPServer()
        let ready = expectation(description: "listener ready")
        var boundPort: UInt16 = 0
        XCTAssertTrue(server.start(port: 0, handler: { _, _, _ in
            (405, #"{"error":"method not allowed"}"#)
        }, onReady: { boundPort = $0; ready.fulfill() }))
        self.server = server
        wait(for: [ready], timeout: 5)

        let result = try XCTUnwrap(get(boundPort, "/api/displays"))

        XCTAssertEqual(result.status, 405)
        XCTAssertTrue(String(data: result.body, encoding: .utf8)?.contains("method not allowed") == true)
    }

    func testServerSurvivesMalformedRequest() throws {
        // A garbage request must not crash or wedge the server: after it,
        // a well-formed request still gets a response.
        let port = startServer()
        let expectation = expectation(description: "garbage sent")
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("not an http request at all\r\n\r\n".utf8)
        URLSession.shared.dataTask(with: request) { _, _, _ in
            expectation.fulfill()
        }.resume()
        wait(for: [expectation], timeout: 5)

        let result = get(port, "/api/displays")
        XCTAssertEqual(result?.status, 200)
    }
}
