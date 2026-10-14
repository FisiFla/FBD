import CPrivateAPI
import CoreGraphics
import Foundation
import IOKit
import os

/// What to read out of a sink's DPCD.
///
/// A value type so the bounds are testable without a display. The entry point clamps the length to
/// 0x1000 itself, which means an oversized request is silently truncated rather than refused — the
/// kind of quiet difference this codebase keeps finding — so this refuses instead, and a caller
/// cannot believe it read more than it did.
public struct DPCDRequest: Equatable, Sendable {
    /// The most the implementation reads in one call (it clamps to this).
    public static let maxLength = 4096
    /// Where a receiver's capability block begins — the part FBD's decoder reads.
    public static let receiverCapabilityAddress: UInt32 = 0x0000

    public let address: UInt32
    public let length: Int

    /// Nil when the request cannot be honoured as asked, rather than clamping it.
    public init?(address: UInt32, length: Int) {
        guard length > 0, length <= Self.maxLength else { return nil }
        self.address = address
        self.length = length
    }
}

/// Why a read produced nothing.
///
/// Distinct cases rather than one nil, because "no DP sink answered" was hiding three different
/// causes — and the first time this ran against the built-in panel, telling them apart was the whole
/// question.
public enum DPCDReadFailure: Error, Equatable, Sendable {
    /// The IODP entry points are not on this macOS.
    case unavailable
    /// No `DCPAVServiceProxy` / `IOAVService` node for the display.
    case noService
    /// `IODPDeviceCreateWithService` declined the service.
    case noDevice
    /// The read call itself refused; carries the implementation's own status.
    case refused(Int32)

    /// For the CLI, which prints it.
    public var description: String {
        switch self {
        case .unavailable: return "the IODP entry points are unavailable on this Mac"
        case .noService: return "no DCPAVServiceProxy / IOAVService node for this display"
        case .noDevice: return "IODPDeviceCreateWithService declined the service"
        case .refused(let status): return "the read was refused (status \(status))"
        }
    }
}

/// The IODP DPCD read path: the AUX route to a DisplayPort receiver's registers, which is where DSC,
/// link training and — per `docs/PRIVATE_APIS.md` — tiling are actually described.
///
/// **Read-only.** The symbols that drive the link (`IODPDeviceWriteDPCD` and the retrain/set calls)
/// resolve on this macOS and are deliberately not declared in the shim: a wrong write can wedge the
/// only attached display, and nothing FBD does needs one.
public enum IODPAPI {
    private static let log = Logger(subsystem: "dev.fisifla.fbd", category: "IODPAPI")

    /// True when both entry points resolved on this macOS.
    public static var isAvailable: Bool { FBDIodpAvailable() }

    /// Read `request` from a display's sink.
    ///
    /// The device is deliberately not released: `IODPDeviceCreateWithService` follows the Create rule
    /// in its name, but nothing in the ledger confirms which ownership convention it uses, and
    /// guessing wrong with `Unmanaged.release` is a crash rather than a leak. One small object per
    /// read, released when the process ends, is the cheaper mistake — and reads are rare here.
    public static func read(_ request: DPCDRequest, for display: Display) -> Result<[UInt8], DPCDReadFailure> {
        guard isAvailable else { return .failure(.unavailable) }

        // Which IOService a DP device is created from differs by display. An external display has a
        // `DCPAVServiceProxy` / `IOAVService` child; the built-in panel here does not, and the entry
        // point accepts the display's own node too. Try both: a service it does not accept yields
        // NULL rather than anything dangerous.
        let candidates = [
            IOAVServiceAPI.findDPService(
                displayID: display.id,
                vendor: display.vendorNumber,
                model: display.modelNumber,
                serial: display.serialNumber
            ),
            IOAVServiceAPI.findDisplayService(
                displayID: display.id,
                vendor: display.vendorNumber,
                model: display.modelNumber,
                serial: display.serialNumber
            ),
        ].compactMap { $0 }
        guard !candidates.isEmpty else { return .failure(.noService) }

        var device: UnsafeMutableRawPointer?
        for service in candidates {
            if let created = FBDIodpDeviceWithService(UInt32(service)) {
                device = created
                break
            }
        }
        candidates.forEach { IOKitSupport.release($0) }
        guard let device else {
            log.debug("IODPDeviceCreateWithService declined every service for display \(display.id)")
            return .failure(.noDevice)
        }

        var buffer = [UInt8](repeating: 0, count: request.length)
        let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
            FBDIodpReadDPCD(
                device,
                request.address,
                raw.bindMemory(to: UInt8.self).baseAddress,
                UInt32(request.length)
            )
        }
        guard status == 0 else {
            log.debug("IODPDeviceReadDPCD refused for display \(display.id): \(status)")
            return .failure(.refused(status))
        }
        return .success(buffer)
    }

    /// The receiver capability block, which is what FBD's decoder understands.
    public static func readReceiverCapability(
        for display: Display,
        length: Int = 16
    ) -> Result<[UInt8], DPCDReadFailure> {
        guard let request = DPCDRequest(address: DPCDRequest.receiverCapabilityAddress, length: length) else {
            return .failure(.refused(-1))
        }
        return read(request, for: display)
    }
}
