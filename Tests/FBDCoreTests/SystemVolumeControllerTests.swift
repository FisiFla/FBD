import CoreAudio
import XCTest
@testable import FBDCore

/// A HAL that never touches a real device, so the behaviours that matter can be
/// provoked deliberately — above all a **slow USB device** and an **HDMI output
/// with no software volume**, which is what the machine FBD was developed on
/// actually has as its default output.
private final class FakeHAL: CoreAudioHAL {
    struct Device {
        var id: AudioDeviceID
        var name: String
        var value: Double?
        var muted = false
    }

    var devices: [Device] = [Device(id: 42, name: "Fake USB DAC", value: 0.5)]
    var defaultID: AudioDeviceID? = 42
    /// Simulates a device that takes its time answering.
    var writeDelay: TimeInterval = 0
    /// A device that accepts the call but settles somewhere else — the "stuck at
    /// ~50%" case. Deterministic, unlike racing a real read-back.
    var refusesWrites = false
    private(set) var writes = 0

    private func index(of id: AudioDeviceID) -> Int? { devices.firstIndex { $0.id == id } }

    func defaultOutputDevice() -> AudioDeviceID? { defaultID }
    func outputDeviceIDs() -> [AudioDeviceID] { devices.map(\.id) }
    func name(of device: AudioDeviceID) -> String? { index(of: device).map { devices[$0].name } }
    func volume(of device: AudioDeviceID) -> Double? { index(of: device).flatMap { devices[$0].value } }

    @discardableResult
    func setVolume(_ value: Double, on device: AudioDeviceID) -> Bool {
        if writeDelay > 0 { Thread.sleep(forTimeInterval: writeDelay) }
        if !refusesWrites, let index = index(of: device) { devices[index].value = value }
        writes += 1
        return true
    }

    func isMuted(_ device: AudioDeviceID) -> Bool? { index(of: device).map { devices[$0].muted } }

    @discardableResult
    func setMuted(_ muted: Bool, on device: AudioDeviceID) -> Bool {
        if let index = index(of: device) { devices[index].muted = muted }
        return true
    }
}

/// System output volume over CoreAudio (#20).
@MainActor
final class SystemVolumeControllerTests: XCTestCase {

    private func controller(_ hal: FakeHAL) -> SystemVolumeController {
        SystemVolumeController(hal: hal, queue: DispatchQueue(label: "test.systemvolume"))
    }

    /// Spin the main run loop until `condition` holds or the deadline passes.
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Learn the target before acting — a write cannot be judged until the
    /// controller knows what it is writing to.
    private func refreshed(_ hal: FakeHAL) async -> SystemVolumeController {
        let subject = controller(hal)
        subject.refresh()
        await waitUntil { subject.deviceName != nil }
        return subject
    }

    // MARK: - Clamping

    func testClampingIsBounded() {
        XCTAssertEqual(SystemVolumeController.clamped(0.5), 0.5)
        XCTAssertEqual(SystemVolumeController.clamped(-3), 0)
        XCTAssertEqual(SystemVolumeController.clamped(7), 1)
    }

    // MARK: - The non-blocking property

    func testASlowDeviceDoesNotBlockTheCaller() async {
        // The acceptance criterion: a slow USB device must not block the UI.
        // The write is deferred and the caller sees the new value at once.
        let hal = FakeHAL()
        let subject = await refreshed(hal)
        hal.writeDelay = 1.0

        let start = Date()
        subject.set(0.25)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.1, "set() must not wait for the device")
        XCTAssertEqual(subject.volume, 0.25, "the requested value is visible immediately")
        XCTAssertEqual(hal.writes, 0, "the HAL write should still be in flight")
    }

    func testTheWriteDoesLandEventually() async {
        let hal = FakeHAL()
        let subject = await refreshed(hal)
        subject.set(0.4)
        await waitUntil { hal.writes > 0 }
        XCTAssertEqual(hal.devices[0].value, 0.4)
    }

    func testAValueTheDeviceRejectsIsCorrectedRatherThanLeftLying() async {
        // The "stuck at ~50%" case: the device accepts the call but settles
        // elsewhere. The optimistic value must be replaced by the truth once the
        // device has answered, not left showing what was asked for.
        let hal = FakeHAL()
        hal.refusesWrites = true
        let subject = await refreshed(hal)

        subject.set(0.9)
        XCTAssertEqual(subject.volume, 0.9, "optimistic to begin with")

        await waitUntil { subject.volume != 0.9 }
        XCTAssertEqual(subject.volume, 0.5, "…must end up reflected, not hidden")
    }

    // MARK: - The honesty property (HDMI outputs)

    func testWritingToADeviceWithNoVolumeControlIsRefusedNotClaimed() async {
        // An HDMI output — a TV's speakers — has no software volume. Printing
        // "set to 30" for a write the HAL drops is worse than failing, so
        // nothing is claimed and no write is even attempted.
        let hal = FakeHAL()
        hal.devices = [FakeHAL.Device(id: 89, name: "LG TV SSCR2", value: nil)]
        hal.defaultID = 89
        let subject = await refreshed(hal)

        XCTAssertFalse(subject.isControllable)
        subject.set(0.5)

        XCTAssertNil(subject.volume, "no value may be claimed for a dropped write")
        XCTAssertEqual(hal.writes, 0, "the HAL should not be asked to write at all")
    }

    func testASelectedDeviceWithNoVolumeControlIsReported() async {
        let hal = FakeHAL()
        hal.devices.append(FakeHAL.Device(id: 75, name: "MacBook Pro Speakers", value: 0.31))
        let subject = await refreshed(hal)
        XCTAssertTrue(subject.isControllable)

        // Move to a device that cannot be controlled…
        hal.devices.append(FakeHAL.Device(id: 104, name: "Scarlett Solo USB", value: nil))
        subject.select(104)
        await waitUntil { subject.selectedDevice == 104 && subject.deviceName == "Scarlett Solo USB" }

        XCTAssertFalse(subject.isControllable, "…and stop claiming it is")
        XCTAssertNil(subject.volume)
    }

    // MARK: - Reading

    func testRefreshPublishesDeviceStateAndTheDeviceList() async {
        let hal = FakeHAL()
        hal.devices.append(FakeHAL.Device(id: 75, name: "MacBook Pro Speakers", value: 0.31))
        let subject = await refreshed(hal)

        XCTAssertEqual(subject.volume, 0.5)
        XCTAssertEqual(subject.deviceName, "Fake USB DAC")
        XCTAssertEqual(subject.devices.count, 2)
        // The controllability of each device is published, so `--list` can say
        // which ones are worth targeting.
        XCTAssertEqual(subject.devices.first { $0.id == 75 }?.hasVolumeControl, true)
    }

    func testNoOutputDeviceAtAll() async {
        let hal = FakeHAL()
        hal.defaultID = nil
        let subject = controller(hal)
        subject.refresh()
        await waitUntil { subject.volume == nil && subject.deviceName == nil }
        XCTAssertFalse(subject.isControllable)
    }

    // MARK: - Media-key stepping

    func testAdjustUsesOneStep() async {
        let hal = FakeHAL()
        let subject = await refreshed(hal)
        subject.set(0.5)
        subject.adjust(by: SystemVolumeController.step)
        XCTAssertEqual(subject.volume!, 0.5 + 0.0625, accuracy: 1e-9)
    }

    func testAdjustingUpFromFullStaysAtFull() async {
        let hal = FakeHAL()
        let subject = await refreshed(hal)
        subject.set(1.0)
        subject.adjust(by: SystemVolumeController.step)
        XCTAssertEqual(subject.volume, 1.0)
    }

    func testMuteTogglesAndIsReported() async {
        let hal = FakeHAL()
        let subject = await refreshed(hal)
        subject.setMuted(false)
        XCTAssertFalse(subject.isMuted)
        subject.toggleMute()
        XCTAssertTrue(subject.isMuted)
        subject.toggleMute()
        XCTAssertFalse(subject.isMuted)
    }

    func testRaisingVolumeClearsMute() async {
        // A muted device that gets a volume-up should be audible, which is what
        // the media keys do.
        let hal = FakeHAL()
        let subject = await refreshed(hal)
        subject.setMuted(true)
        subject.set(0.5)
        XCTAssertFalse(subject.isMuted)
    }

    func testMuteIsRefusedOnADeviceWithNoVolumeControlToo() async {
        let hal = FakeHAL()
        hal.devices = [FakeHAL.Device(id: 89, name: "LG TV SSCR2", value: nil)]
        hal.defaultID = 89
        let subject = await refreshed(hal)
        subject.setMuted(true)
        XCTAssertFalse(subject.isMuted)
    }
}
