import CoreFoundation
import CPrivateAPI
import Foundation
import os

/// The I2C transport surface DDCController depends on. Extracted so the DDC
/// controller can be tested with a mock transport (no real hardware needed).
public protocol ExternalControlling: AnyObject {
    /// The AVService ref for a display (nil when unavailable). Only use the
    /// returned ref synchronously within a single call.
    func avService(for display: Display) -> IOAVServiceRef?

    /// Raw I2C read (DDC address 0x37, EDID address 0x50).
    func readI2C(_ address: UInt8, length: Int, for display: Display) -> Data?

    /// Raw I2C write. Returns false when no AVService is available or the
    /// transaction fails.
    @discardableResult
    func writeI2C(_ address: UInt8, data: Data, for display: Display) -> Bool

    /// Drop all cached services (call after display topology changes).
    func invalidateCache()
}

/// Owns the IOAVService (DDC/EDID I2C transport) lifecycle for external
/// displays on Apple Silicon, plus raw I2C read/write access.
///
/// AVService lookup walks the IORegistry, which is expensive; results are
/// cached per display identity. Negative results are cached for 30 seconds
/// so we don't hammer the registry when DDC is repeatedly probed.
public final class ExternalController: ExternalControlling {
    /// Retains an IOAVServiceRef (CF type) and releases it on deinit.
    final class AVServiceHandle {
        let ref: IOAVServiceRef

        init?(_ ref: IOAVServiceRef?) {
            guard let ref else { return nil }
            self.ref = ref
        }

        deinit { Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(ref)).release() }
    }

    private struct CacheEntry {
        let handle: AVServiceHandle?
        let timestamp: Date
    }

    /// How long a failed lookup is remembered before retrying.
    private let negativeCacheDuration: TimeInterval = 30

    private var cache: [String: CacheEntry] = [:]
    private let cacheLock = NSLock()
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "ExternalController")

    public init() {}

    /// The cached handle for a display, resolving it on first use.
    /// Returns nil on Intel, under Rosetta, or when no AVService exists.
    private func handle(for display: Display) -> AVServiceHandle? {
        let key = display.identityKey
        let now = Date()

        cacheLock.lock()
        if let entry = cache[key] {
            if let handle = entry.handle {
                cacheLock.unlock()
                return handle
            }
            // Negative result: respect the cooldown window before retrying.
            if now.timeIntervalSince(entry.timestamp) < negativeCacheDuration {
                cacheLock.unlock()
                return nil
            }
            // Expired negative result: fall through to a fresh lookup.
        }
        cacheLock.unlock()

        guard IOAVServiceAPI.isAppleSilicon else {
            rememberNegative(key, at: now)
            return nil
        }

        guard let ref = IOAVServiceAPI.findAVService(
            displayID: display.id,
            vendor: display.vendorNumber,
            model: display.modelNumber,
            serial: display.serialNumber
        ) else {
            log.debug("No AVService for \(display.id) (\(key))")
            rememberNegative(key, at: now)
            return nil
        }

        let handle = AVServiceHandle(ref)
        cacheLock.lock()
        cache[key] = CacheEntry(handle: handle, timestamp: now)
        cacheLock.unlock()
        return handle
    }

    /// The AVService ref for a display. The returned ref is owned by the
    /// internal cache; only use it synchronously within a single call (see
    /// `readI2C`/`writeI2C`, which keep the handle alive for the duration).
    public func avService(for display: Display) -> IOAVServiceRef? {
        handle(for: display)?.ref
    }

    /// Raw I2C read (e.g. DDC address 0x37, EDID address 0x50).
    /// Keeps the AVService handle alive for the duration of the transaction.
    public func readI2C(_ address: UInt8, length: Int, for display: Display) -> Data? {
        guard let handle = handle(for: display) else { return nil }
        return IOAVServiceAPI.readI2C(handle.ref, address: address, length: length)
    }

    /// Raw I2C write. Returns false when no AVService is available or the
    /// transaction fails. Keeps the AVService handle alive for the duration.
    @discardableResult
    public func writeI2C(_ address: UInt8, data: Data, for display: Display) -> Bool {
        guard let handle = handle(for: display) else { return false }
        return IOAVServiceAPI.writeI2C(handle.ref, address: address, data: data)
    }

    /// Drop all cached services (call after display topology changes).
    /// Handles currently in use by an in-flight transaction stay alive via
    /// their local strong refs and release when that transaction finishes.
    public func invalidateCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    private func rememberNegative(_ key: String, at date: Date) {
        cacheLock.lock()
        cache[key] = CacheEntry(handle: nil, timestamp: date)
        cacheLock.unlock()
    }
}
