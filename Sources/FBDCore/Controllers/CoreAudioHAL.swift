import CoreAudio
import Foundation

/// The CoreAudio HAL surface, behind a protocol so the caching, clamping and
/// non-blocking behaviour of `SystemVolumeController` can be tested without an
/// audio device — and without a slow USB device to wait for.
public protocol CoreAudioHAL: AnyObject {
    /// The current default output device, or nil when there is none.
    func defaultOutputDevice() -> AudioDeviceID?
    /// Devices with at least one output stream.
    func outputDeviceIDs() -> [AudioDeviceID]
    func name(of device: AudioDeviceID) -> String?
    /// 0…1, or nil when the device exposes no scalar volume (some USB and
    /// virtual devices do not).
    func volume(of device: AudioDeviceID) -> Double?
    @discardableResult func setVolume(_ value: Double, on device: AudioDeviceID) -> Bool
    func isMuted(_ device: AudioDeviceID) -> Bool?
    @discardableResult func setMuted(_ muted: Bool, on device: AudioDeviceID) -> Bool
}

/// The real HAL. Every call here is a synchronous round trip to coreaudiod —
/// and to the device itself, which is why a slow USB DAC can block for hundreds
/// of milliseconds. `SystemVolumeController` is what keeps that off the UI path.
public final class CoreAudioHal: CoreAudioHAL {
    public init() {}

    public func defaultOutputDevice() -> AudioDeviceID? {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != 0 else { return nil }
        return device
    }

    public func outputDeviceIDs() -> [AudioDeviceID] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let object = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &devices) == noErr else {
            return []
        }
        return devices.filter(hasOutputStreams)
    }

    public func name(of device: AudioDeviceID) -> String? {
        var address = Self.address(kAudioObjectPropertyName)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer -> OSStatus in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, (name as String).isEmpty == false else { return nil }
        return name as String
    }

    public func volume(of device: AudioDeviceID) -> Double? {
        // Scalar volume lives on the main element on most devices and per-channel
        // on others, so both are tried. A device with neither simply has no
        // software volume control.
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
            var address = Self.address(
                kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                return Double(value)
            }
        }
        return nil
    }

    @discardableResult
    public func setVolume(_ value: Double, on device: AudioDeviceID) -> Bool {
        let clamped = Float32(min(max(value, 0), 1))
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
            var address = Self.address(
                kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            var scalar = clamped
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(device, &address, 0, nil, size, &scalar) == noErr {
                return true
            }
        }
        return false
    }

    public func isMuted(_ device: AudioDeviceID) -> Bool? {
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return nil }
        return muted != 0
    }

    @discardableResult
    public func setMuted(_ muted: Bool, on device: AudioDeviceID) -> Bool {
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value = UInt32(muted ? 1 : 0)
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    // MARK: - Helpers

    private func hasOutputStreams(_ device: AudioDeviceID) -> Bool {
        var address = Self.address(
            kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}
