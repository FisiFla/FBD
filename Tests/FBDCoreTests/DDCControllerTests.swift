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
    var onWrite: (() -> Void)?

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
        onWrite?()
        return !shouldFailWrites
    }

    func invalidateCache() {}
}

final class DDCControllerTests: XCTestCase {
    /// m1ddc-style 12-byte get-VCP reply: code 0x10, max 100, current 50.
    /// The checksum is the display's bus address (0x50) XORed over the frame,
    /// which is what a reply has to carry to be believed.
    private static let brightnessReply: Data = {
        let frame: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32]
        return Data(frame + [DDC.replyChecksum(frame), 0x00])
    }()

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
        // Platform check injected: the mock transport does not need Apple
        // Silicon, so these tests run on any CI architecture.
        DDCController(external: mock, isPlatformSupported: { true })
    }

    // MARK: - Async reads (queue re-entry)

    /// `readState` runs on the display's queue and must not re-enter it.
    ///
    /// `readVCP` does `queue.sync` internally, so a wrapper that called it from
    /// inside `queue.async` would deadlock: the callback would never fire and the
    /// display's queue would never drain. That failure is silent — the DDC panel
    /// would simply stop updating rather than report anything — and the compiler
    /// cannot catch it, which is exactly why this asserts the callback arrives.
    func testReadStateCompletesRatherThanDeadlocking() {
        let mock = MockExternal()
        mock.readScript = [Self.brightnessReply]
        let controller = makeController(mock: mock)

        let answered = expectation(description: "readState returned")
        controller.readState(for: display) { state in
            // Firing at all is the assertion. The scripted packet is a brightness
            // reply, so the individual values are not meaningful for this test.
            _ = state
            answered.fulfill()
        }
        // A deadlock fails here after the timeout instead of hanging the suite.
        wait(for: [answered], timeout: 5)

        XCTAssertGreaterThan(mock.writeCalls, 0, "the reads should have reached the transport")
    }

    // MARK: - Read retries

    func testReadVCPSucceedsOnFirstAttempt() {
        let mock = MockExternal()
        mock.readScript = [Self.brightnessReply]
        let controller = makeController(mock: mock)

        let value = controller.readVCP(0x10, for: display)

        XCTAssertEqual(value, DDC.DDCValue(maxValue: 100, currentValue: 50))
        XCTAssertEqual(mock.readCalls, 1)
        // The request packet for VCP 0x10 must have been written.
        XCTAssertEqual(mock.lastWriteData, Data(DDC.readVCPRequest(code: 0x10)))
    }

    func testReadVCPRetriesWhenDisplayDoesNotAnswerFirst() throws {
        let mock = MockExternal()
        // First read: no reply (nil). Second read: valid reply.
        mock.readScript = [nil, Self.brightnessReply]
        let controller = makeController(mock: mock)

        let value = controller.readVCP(0x10, for: display)

        XCTAssertEqual(value, DDC.DDCValue(maxValue: 100, currentValue: 50))
        XCTAssertEqual(mock.readCalls, 2)
    }

    func testReadVCPRetriesUntilSuccessAcrossMultipleFailures() {
        let mock = MockExternal()
        mock.readScript = [nil, nil, Self.brightnessReply]
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

    func testReadVCPDoesNotExceedRetryBudgetWhenRequestWriteFails() throws {
        let mock = MockExternal()
        mock.shouldFailWrites = true
        mock.readScript = [Self.brightnessReply]
        let controller = makeController(mock: mock)
        let previous = Settings.ddcReadRetries
        Settings.ddcReadRetries = 0
        defer { Settings.ddcReadRetries = previous }

        let value = controller.readVCP(0x10, for: display)

        XCTAssertNil(value)
        XCTAssertEqual(mock.writeCalls, 1)
        XCTAssertEqual(mock.readCalls, 0)
    }

    func testReadVCPRetriesWhenRequestWriteFails() throws {
        let mock = MockExternal()
        mock.shouldFailWrites = true
        mock.readScript = [Self.brightnessReply]
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

    func testWriteVCPDeliversPacketOnDisplayQueue() throws {
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

    func testWriteVCPCoalescesPendingWritesLatestWinsPerCode() {
        let mock = MockExternal()
        let controller = makeController(mock: mock)
        let previous = Settings.ddcCooldownMilliseconds
        Settings.ddcCooldownMilliseconds = 300
        defer { Settings.ddcCooldownMilliseconds = previous }
        let delivered = expectation(description: "writes delivered")
        delivered.expectedFulfillmentCount = 2
        mock.onWrite = { delivered.fulfill() }

        // The first write takes the immediate slot, so the three code-0x10 writes below
        // all land while their (cooldown-delayed) slot is still pending.
        controller.writeVCP(0x12, value: 1, for: display)
        controller.writeVCP(0x10, value: 10, for: display)
        controller.writeVCP(0x10, value: 20, for: display)
        controller.writeVCP(0x10, value: 30, for: display)

        wait(for: [delivered], timeout: 3)
        // Leave room for any (wrong) extra writes to show up.
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(mock.writeCalls, 2)
        XCTAssertEqual(mock.lastWriteData, Data(DDC.writeVCPPacket(code: 0x10, value: 30)))
    }

    func testWriteVCPKeepsDifferentCodesIndependent() {
        let mock = MockExternal()
        let controller = makeController(mock: mock)
        let previous = Settings.ddcCooldownMilliseconds
        Settings.ddcCooldownMilliseconds = 10
        defer { Settings.ddcCooldownMilliseconds = previous }
        let delivered = expectation(description: "both codes delivered")
        delivered.expectedFulfillmentCount = 2
        mock.onWrite = { delivered.fulfill() }

        controller.writeVCP(0x10, value: 10, for: display)
        controller.writeVCP(0x12, value: 20, for: display)

        wait(for: [delivered], timeout: 3)
        XCTAssertEqual(mock.writeCalls, 2)
    }

    // MARK: - Read cache

    func testRepeatedReadsAreServedFromTheCache() {
        let mock = MockExternal()
        mock.readScript = [Self.brightnessReply]
        let controller = makeController(mock: mock)

        XCTAssertNotNil(controller.readVCP(0x10, for: display))
        XCTAssertNotNil(controller.readVCP(0x10, for: display))

        XCTAssertEqual(mock.readCalls, 1, "the second read should come from the cache")
    }

    func testAWriteInvalidatesTheCachedRead() {
        let mock = MockExternal()
        mock.readScript = [Self.brightnessReply]
        let controller = makeController(mock: mock)
        let previous = Settings.ddcCooldownMilliseconds
        Settings.ddcCooldownMilliseconds = 10
        defer { Settings.ddcCooldownMilliseconds = previous }

        XCTAssertNotNil(controller.readVCP(0x10, for: display))
        XCTAssertEqual(mock.readCalls, 1)

        controller.writeVCP(0x10, value: 75, for: display)
        // The write is delivered asynchronously; give it a moment.
        let delivered = expectation(description: "write delivered")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { delivered.fulfill() }
        wait(for: [delivered], timeout: 2)

        // The display now holds a value we have not read back: the next read
        // has to ask it again.
        XCTAssertNotNil(controller.readVCP(0x10, for: display))
        XCTAssertEqual(mock.readCalls, 2)
    }

    // MARK: - Quarantine

    func testRepeatedFailuresQuarantineTheDisplay() {
        let mock = MockExternal()
        mock.readScript = [nil]
        let controller = DDCController(
            external: mock,
            isPlatformSupported: { true },
            readHealth: DDCReadHealth(failureThreshold: 2)
        )
        let previous = Settings.ddcReadRetries
        Settings.ddcReadRetries = 0
        defer { Settings.ddcReadRetries = previous }

        XCTAssertNil(controller.readVCP(0x10, for: display))
        XCTAssertNil(controller.readVCP(0x10, for: display))

        // The third read is refused outright — no bus traffic at all.
        let callsBefore = mock.readCalls
        XCTAssertNil(controller.readVCP(0x10, for: display))
        XCTAssertEqual(mock.readCalls, callsBefore, "a quarantined display must not be asked again")
    }

    // MARK: - Traffic gate

    func testReadsAreRefusedWhileTheDisplayTopologyChanges() {
        let mock = MockExternal()
        mock.readScript = [Self.brightnessReply]
        let pool = DDCQueuePool()
        let controller = DDCController(
            external: mock,
            isPlatformSupported: { true },
            queuePool: pool
        )

        let hold = pool.hold()

        XCTAssertNil(controller.readVCP(0x10, for: display))
        XCTAssertEqual(mock.writeCalls, 0, "no bus traffic while a topology change is in progress")
        XCTAssertEqual(mock.readCalls, 0)

        hold.release()

        XCTAssertNotNil(controller.readVCP(0x10, for: display))
        XCTAssertEqual(mock.readCalls, 1)
    }

    // MARK: - Capabilities

    func testReadCapabilitiesAssemblesFragmentsByOffset() throws {
        // The capabilities string comes back in fragments, each requested by offset;
        // an empty fragment ends it.
        let text = Array("(vcp(10 60 62)F(1)mccs_ver(2.2)".utf8)
        let first = Array(text.prefix(16)), second = Array(text.dropFirst(16))
        func fragment(_ offset: Int, _ payload: [UInt8]) -> Data {
            Data([0x6E, UInt8(0x80 | (payload.count + 3)), 0xE3, UInt8(offset >> 8), UInt8(offset & 0xFF)] + payload + [0x00])
        }
        let mock = MockExternal()
        mock.readScript = [fragment(0, first), fragment(16, second), fragment(text.count, [])]
        let controller = makeController(mock: mock)

        let caps = controller.readCapabilities(for: display)

        XCTAssertNotNil(caps)
        XCTAssertEqual(caps?.vcpCodes, [0x10, 0x60, 0x62])
        XCTAssertEqual(caps?.mccsVersion, "2.2")
        XCTAssertEqual(mock.lastWriteData, Data(DDC.capabilitiesRequest(offset: UInt16(text.count))))
    }
}
