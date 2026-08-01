import XCTest
import FBDCore

/// Mock I2C transport for DDCController tests (no hardware required).
/// Each `Display` needs an `identityKey` — the fixture display uses a fixed
/// vendor/model/serial so the key is stable across the test suite.
private final class MockExternal: ExternalControlling {
    /// Scripted per-read responses; consumed in order. When the script runs
    /// out, the last entry is repeated.
    var readScript: [Data?] = []
    var readCalls = 0
    var writeCalls = 0
    var lastWriteData: Data?
    var shouldFailWrites = false

    func avService(for display: Display) -> OpaquePointer? {
        // Any non-nil sentinel satisfies DDCController.isAvailable.
        OpaquePointer(bitPattern: 1)
    }

    func readI2C(_ address: UInt8, length: Int, for display: Display) -> Data? {
        readCalls += 1
        guard !readScript.isEmpty else { return nil }
        let index = min(readCalls - 1, readScript.count - 1)
        return readScript[index]
    }

    func writeI2C(_ address: UInt8, data: Data, for display: Display) -> Bool {
        writeCalls += 1
        lastWriteData = data
        return !shouldFailWrites
    }

    func invalidateCache() {}
}

final class DDCControllerTests: XCTestCase {
    private var display: Display {
        Display(
            id: 0x1234,
            name: "Mock Monitor",
            isBuiltin: false,
            vendorNumber: 0x1234,
            modelNumber: 0x5678,
            serialNumber: 0x11223344,
            bounds: .zero,
            isOnline: true,
            isActive: true
        )
    }

    private func makeController(mock: MockExternal) -> DDCController {
        DDCController(external: mock)
    }

    // MARK: - Read retries

    func testReadVCPSucceedsOnFirstAttempt() {
        let mock = MockExternal()
        mock.readScript = [Data([0x6E, 0x10, 0x03, 0x00, 0x64, 0x00, 0x32, 0x6F])]
        let controller = makeController(mock: mock)

        let value = controller.readVCP(0x10, for: display)

        XCTAssertEqual(value, DDC.DDCValue(maxValue: 100, currentValue: 50))
        XCTAssertEqual(mock.readCalls, 1)
        // The request packet for VCP 0x10 must have been written.
        XCTAssertEqual(mock.lastWriteData, Data(DDC.readVCPRequest(code: 0x10)))
    }

    func testReadVCPRetriesWhenDisplayDoesNotAnswerFirst() {
        let mock = MockExternal()
        // First read: no reply (nil). Second read: valid reply.
        mock.readScript = [nil, Data([0x6E, 0x10, 0x03, 0x00, 0x64, 0x00, 0x32, 0x6F])]
        let controller = makeController(mock: mock)

        let value = controller.readVCP(0x10, for: display)

        XCTAssertEqual(value, DDC.DDCValue(maxValue: 100, currentValue: 50))
        XCTAssertEqual(mock.readCalls, 2)
    }

    func testReadVCPRetriesUntilSuccessAcrossMultipleFailures() {
        let mock = MockExternal()
        mock.readScript = [nil, nil, Data([0x6E, 0x10, 0x03, 0x00, 0x64, 0x00, 0x32, 0x6F])]
        let controller = makeController(mock: mock)
        // Lower the retry budget so the test is fast: total attempts = 3.
        let previous = Settings.ddcReadRetries
        Settings.ddcReadRetries = 2
        defer { Settings.ddcReadRetries = previous }

        let value = controller.readVCP(0x10, for: display)

        XCTAssertEqual(value, DDC.DDCValue(maxValue: 100, currentValue: 50))
        XCTAssertEqual(mock.readCalls, 3)
    }

    func testReadVCPGivesUpAfterExhaustingRetries() {
        let mock = MockExternal()
        mock.readScript = [nil]
        let controller = makeController(mock: mock)
        let previous = Settings.ddcReadRetries
        Settings.ddcReadRetries = 1
        defer { Settings.ddcReadRetries = previous }

        let value = controller.readVCP(0x10, for: display)

        XCTAssertNil(value)
        XCTAssertEqual(mock.readCalls, 2) // initial + 1 retry
    }

    func testReadVCPDoesNotExceedRetryBudgetWhenRequestWriteFails() {
        let mock = MockExternal()
        mock.shouldFailWrites = true
        mock.readScript = [Data([0x6E, 0x10, 0x03, 0x00, 0x64, 0x00, 0x32, 0x6F])]
        let controller = makeController(mock: mock)
        let previous = Settings.ddcReadRetries
        Settings.ddcReadRetries = 0
        defer { Settings.ddcReadRetries = previous }

        let value = controller.readVCP(0x10, for: display)

        XCTAssertNil(value)
        XCTAssertEqual(mock.writeCalls, 1)
        XCTAssertEqual(mock.readCalls, 0)
    }

    func testReadVCPRetriesWhenRequestWriteFails() {
        let mock = MockExternal()
        mock.shouldFailWrites = true
        mock.readScript = [Data([0x6E, 0x10, 0x03, 0x00, 0x64, 0x00, 0x32, 0x6F])]
        let controller = makeController(mock: mock)
        let previous = Settings.ddcReadRetries
        Settings.ddcReadRetries = 1
        defer { Settings.ddcReadRetries = previous }

        let value = controller.readVCP(0x10, for: display)

        // Retrying covers the whole transaction, so a flaky request write is
        // retried too (total attempts = retries + 1).
        XCTAssertNil(value)
        XCTAssertEqual(mock.writeCalls, 2)
        XCTAssertEqual(mock.readCalls, 0)
    }

    // MARK: - Writes

    func testWriteVCPDeliversPacketOnDisplayQueue() {
        let mock = MockExternal()
        let controller = makeController(mock: mock)
        let expectation = expectation(description: "async DDC write delivered")

        let accepted = controller.writeVCP(0x10, value: 75, for: display)

        XCTAssertTrue(accepted)
        // The write lands on the per-display serial queue (async, cooldown-spaced).
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(mock.writeCalls, 1)
        XCTAssertEqual(mock.lastWriteData, Data(DDC.writeVCPPacket(code: 0x10, value: 75)))
    }

    // MARK: - Capabilities

    func testReadCapabilitiesConcatenatesChunkedReply() {
        // A full capabilities reply (header + payload + terminator) split
        // mid-payload across two reads; the third read returns nil so the
        // loop stops.
        let payload = Array("(vcp(10 60 62)F(1)mccs_ver(2.2)".utf8)
        var full = Data([0x6F, 0xF3, 0x00, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        full.append(contentsOf: payload)
        full.append(0x6F)
        let split = 11
        let mock = MockExternal()
        mock.readScript = [
            Data(full.prefix(split)),
            Data(full.dropFirst(split)),
            nil,
        ]
        let controller = makeController(mock: mock)

        let caps = controller.readCapabilities(for: display)

        XCTAssertNotNil(caps)
        XCTAssertEqual(caps?.vcpCodes, [0x10, 0x60, 0x62])
        XCTAssertEqual(caps?.mccsVersion, "2.2")
    }
}
