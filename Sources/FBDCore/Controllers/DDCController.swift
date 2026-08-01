import Foundation
import os

/// DDC/CI controller: VCP reads/writes and capabilities over the Apple Silicon
/// IOAVService I2C transport.
///
/// Concurrency model:
/// - All I2C traffic for a display is serialized on a per-display queue.
/// - **Set-VCP writes are enqueued asynchronously** and spaced by
///   `Settings.ddcCooldownMilliseconds` (some displays glitch when the DDC bus
///   is hammered — OSD flicker, dropped replies). `writeVCP` returns
///   immediately; it only reports whether the request was accepted for delivery.
/// - **Reads are synchronous** (fast: request write + ~30 ms settle + reply
///   read) and are NOT cooldown-gated — they are rare (explicit user actions).
///   They may block the calling thread briefly; never call them from a hot path.
///
/// Never throws: failures degrade to nil/false with a logged warning.
public final class DDCController {
    private let external: ExternalController
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "DDCController")

    /// Per-display serial queues keyed by display identity.
    private var queues: [String: DispatchQueue] = [:]
    /// Next allowed set-write deadline per display (cooldown bookkeeping).
    private var nextWriteAt: [String: DispatchTime] = [:]
    /// Cached maximum values from the last successful VCP read, keyed by display → code.
    private var lastMaxValue: [String: [UInt8: UInt16]] = [:]
    /// Displays we already attempted a live capabilities read for (fallback path).
    private var liveCapabilitiesChecked: Set<String> = []
    private let lock = NSLock()

    public init(external: ExternalController) {
        self.external = external
    }

    // MARK: - Availability

    /// DDC is usable when running natively on Apple Silicon and an AVService
    /// exists for the display.
    public func isAvailable(for display: Display) -> Bool {
        guard IOAVServiceAPI.isAppleSilicon else { return false }
        return external.avService(for: display) != nil
    }

    // MARK: - Queue + write scheduling

    private func queue(for display: Display) -> DispatchQueue {
        let key = display.identityKey
        lock.lock()
        defer { lock.unlock() }
        if let queue = queues[key] { return queue }
        let queue = DispatchQueue(label: "dev.fisifla.fbd.ddc.\(key)")
        queues[key] = queue
        return queue
    }

    /// Reserve the next allowed set-write slot for a display and return its
    /// deadline. Consecutive calls are spaced by the cooldown.
    private func nextWriteSlot(for key: String) -> DispatchTime {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now()
        let slot = max(nextWriteAt[key] ?? now, now)
        nextWriteAt[key] = slot + .milliseconds(Settings.ddcCooldownMilliseconds)
        return slot
    }

    // MARK: - VCP

    /// Read a VCP feature. Synchronous: write request → 30 ms settle → read
    /// 8-byte reply → parse. Returns nil on any failure.
    public func readVCP(_ code: UInt8, for display: Display) -> DDC.DDCValue? {
        guard isAvailable(for: display) else { return nil }
        return queue(for: display).sync {
            guard external.writeI2C(DDC.i2cAddress, data: Data(DDC.readVCPRequest(code: code)), for: display) else {
                log.warning("readVCP: request write failed for \(display.id) (code \(String(format: "0x%02X", code)))")
                return nil
            }
            // Give the display a moment to prepare its reply.
            Thread.sleep(forTimeInterval: 0.03)
            guard let reply = external.readI2C(DDC.i2cAddress, length: 8, for: display) else {
                log.warning("readVCP: no reply for \(display.id) (code \(String(format: "0x%02X", code)))")
                return nil
            }
            guard let parsed = DDC.parseVCPReply(reply) else {
                log.warning("readVCP: malformed reply for \(display.id) (code \(String(format: "0x%02X", code)))")
                return nil
            }
            rememberMax(parsed.value.maxValue, code: code, for: display)
            return parsed.value
        }
    }

    /// Write a VCP feature. Returns true when the write was accepted for
    /// delivery (display has an AVService and the op is queued); delivery is
    /// asynchronous and spaced by the per-display cooldown.
    @discardableResult
    public func writeVCP(_ code: UInt8, value: UInt16, for display: Display) -> Bool {
        guard isAvailable(for: display) else { return false }
        let key = display.identityKey
        let q = queue(for: display)
        let slot = nextWriteSlot(for: key)
        q.asyncAfter(deadline: slot) { [weak self] in
            guard let self else { return }
            let data = Data(DDC.writeVCPPacket(code: code, value: value))
            guard self.external.writeI2C(DDC.i2cAddress, data: data, for: display) else {
                self.log.warning("writeVCP failed for \(display.id) (code \(String(format: "0x%02X", code)))")
                return
            }
        }
        return true
    }

    /// High-level feature read: continuous features return a normalized 0…1
    /// value, discrete features (mute, input source) return the raw current value.
    public func getFeature(_ feature: DDCFeature, for display: Display) -> Double? {
        guard let value = readVCP(feature.vcpCode, for: display) else { return nil }
        if feature.isContinuous {
            return value.normalized
        }
        return Double(value.currentValue)
    }

    /// High-level feature write: continuous features scale `value` (0…1)
    /// against the feature's maximum; discrete features take the raw value.
    /// Asynchronous — returns whether the write was accepted for delivery.
    @discardableResult
    public func setFeature(_ feature: DDCFeature, value: Double, for display: Display) -> Bool {
        let raw: UInt16
        if feature.isContinuous {
            let clamped = min(max(value, 0), 1)
            let maxValue = maxValue(for: feature.vcpCode, display: display)
            raw = UInt16((clamped * Double(maxValue)).rounded())
        } else {
            raw = UInt16(min(max(value, 0), 65535))
        }
        guard writeVCP(feature.vcpCode, value: raw, for: display) else {
            log.warning("setFeature \(feature.settingsKey) failed for \(display.id)")
            return false
        }
        return true
    }

    // MARK: - Capabilities

    /// Read and parse the display's capabilities reply (VCP 0xF3).
    /// Some displays deliver the reply in chunks; up to three sequential
    /// 256-byte reads are attempted and concatenated.
    public func readCapabilities(for display: Display) -> DDC.DDCCapabilities? {
        guard isAvailable(for: display) else { return nil }
        return queue(for: display).sync {
            guard external.writeI2C(DDC.i2cAddress, data: Data(DDC.capabilitiesRequest), for: display) else {
                log.warning("readCapabilities: request write failed for \(display.id)")
                return nil
            }
            Thread.sleep(forTimeInterval: 0.03)
            var collected = Data()
            for _ in 0..<3 {
                guard let chunk = external.readI2C(DDC.i2cAddress, length: 256, for: display) else { break }
                collected.append(chunk)
                if let text = DDC.parseCapabilitiesText(collected) {
                    let caps = DDC.parseCapabilities(text)
                    lock.lock()
                    liveCapabilitiesChecked.remove(display.identityKey)
                    lock.unlock()
                    return caps
                }
                if collected.count >= 256 + 256 { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            log.warning("readCapabilities: no valid reply for \(display.id)")
            return nil
        }
    }

    /// Read capabilities, persist the VCP feature set per display identity,
    /// and update the display's DDC status.
    public func autoConfigure(for display: Display) {
        guard let caps = readCapabilities(for: display) else {
            log.warning("autoConfigure: capabilities read failed for \(display.id)")
            return
        }
        Settings.setDDCFeatures(caps.vcpCodes, for: display.identityKey)
        display.updateDDCStatus(available: true, capabilities: caps)
    }

    /// Whether a feature is supported, from the persisted feature set
    /// (written by `autoConfigure`). Falls back to one live capabilities read
    /// per display when nothing is persisted yet.
    public func isFeatureAvailable(_ feature: DDCFeature, for display: Display) -> Bool {
        let key = display.identityKey
        let persisted = Settings.ddcFeatures(for: key)
        if !persisted.isEmpty {
            return persisted.contains(feature.vcpCode)
        }
        guard isAvailable(for: display) else { return false }

        lock.lock()
        let alreadyChecked = liveCapabilitiesChecked.contains(key)
        lock.unlock()
        guard !alreadyChecked else { return false }

        if let caps = readCapabilities(for: display) {
            Settings.setDDCFeatures(caps.vcpCodes, for: key)
            display.updateDDCStatus(available: true, capabilities: caps)
            return caps.supports(feature.vcpCode)
        }
        lock.lock()
        liveCapabilitiesChecked.insert(key)
        lock.unlock()
        return false
    }

    // MARK: - Helpers

    private func rememberMax(_ maxValue: UInt16, code: UInt8, for display: Display) {
        let key = display.identityKey
        lock.lock()
        var byCode = lastMaxValue[key] ?? [:]
        byCode[code] = maxValue
        lastMaxValue[key] = byCode
        lock.unlock()
    }

    /// Best-known maximum for a continuous feature: cached from the last
    /// successful VCP read, falling back to the MCCS standard 0…100 range.
    /// (Reading the maximum before every write would double I2C traffic and
    /// trip the write cooldown.)
    private func maxValue(for code: UInt8, display: Display) -> UInt16 {
        let key = display.identityKey
        lock.lock()
        let cached = lastMaxValue[key]?[code]
        lock.unlock()
        return cached ?? 100
    }
}
