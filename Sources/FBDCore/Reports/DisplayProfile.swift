import Foundation

/// One report field: a name, and either a value or the reason the value is absent.
///
/// The value is a string because these are report fields, not program state — "HBR3
/// (8.10 Gbps/lane)" and "not read" are both display facts, and a typed model would only
/// move the "how is this rendered" decision somewhere else.
///
/// What the type enforces is the rule the report depends on: **a field cannot hold a value
/// and an excuse at the same time.** Either a fact was read, or it was not and the reason
/// says why.
public struct DiagnosticField: Equatable {
    /// The field's name, as the report shows it.
    public let name: String
    /// The measured value, when there was one.
    public let value: String?
    /// Why there is no value, when there is none.
    public let unavailableReason: String?

    /// A field with a measured value.
    public init(name: String, value: String) {
        self.name = name
        self.value = value
        self.unavailableReason = nil
    }

    /// A field that could not be read, and why.
    public init(name: String, unavailableReason: String) {
        self.name = name
        self.value = nil
        self.unavailableReason = unavailableReason
    }

    /// True when the field carries a measured value.
    public var isAvailable: Bool { value != nil }
}

/// A group of related report fields — one panel, one link, one connection.
///
/// The order of `fields` is the order they are printed in, so a group reads the same way
/// in every report.
public struct DiagnosticGroup: Equatable {
    /// The group's heading.
    public let title: String
    /// The fields, in display order.
    public let fields: [DiagnosticField]

    public init(title: String, fields: [DiagnosticField]) {
        self.title = title
        self.fields = fields
    }

    /// A group whose fields could not be read at all.
    public init(title: String, unavailableReason: String, fieldNames: [String]) {
        self.init(
            title: title,
            fields: fieldNames.map { DiagnosticField(name: $0, unavailableReason: unavailableReason) }
        )
    }

    /// The one reason every field shares, when they all share one.
    ///
    /// A group that could not be read at all has the same reason on every field, and
    /// printing it once reads better than printing it thirteen times. A group where only
    /// some fields are missing has no single reason, and is printed in full.
    public var sharedUnavailableReason: String? {
        guard let first = fields.first?.unavailableReason, !first.isEmpty else { return nil }
        return fields.allSatisfy { $0.unavailableReason == first } ? first : nil
    }
}

/// The EDID facts a report carries.
///
/// The serial is masked **before** it gets here: a display's serial identifies the unit,
/// and this value is about to be written into a file the user may paste anywhere.
public struct DisplayEDIDSummary: Equatable {
    /// How many bytes the EDID had (128 for a base block, 256 for base + extension).
    public let byteCount: Int
    /// The three-letter PNP manufacturer code, e.g. "APP".
    public let manufacturer: String
    /// The EDID product code.
    public let productCode: UInt16
    /// The serial, masked.
    public let serialNumber: String
    /// Week of manufacture.
    public let weekOfManufacture: Int
    /// Year of manufacture.
    public let yearOfManufacture: Int
    /// EDID version, major.
    public let versionMajor: Int
    /// EDID version, minor.
    public let versionMinor: Int
    /// Whether the panel is digital.
    public let isDigital: Bool
    /// The advertised gamma.
    public let gamma: Double
    /// Maximum image size, centimetres, horizontally.
    public let horizontalSizeCM: Int
    /// Maximum image size, centimetres, vertically.
    public let verticalSizeCM: Int
    /// The monitor name the panel advertises, when it has one.
    public let monitorName: String?
    /// The preferred timing the panel advertises, e.g. "2560x1440".
    public let preferredTiming: String?
    /// Whether the base block's checksum is valid.
    public let checksumValid: Bool
}

/// Everything a report knows about one display's hardware, beyond the window server's
/// view of it.
///
/// Every part is optional and nothing is defaulted. A fact that could not be read is
/// reported as absent **with its reason**, so a report never leaves a zero behind that
/// reads like a measurement.
public struct DisplayProfile: Equatable {
    /// The panel's EDID summary, when one could be read.
    public var edid: DisplayEDIDSummary?
    /// Why there is no EDID summary.
    public var edidUnavailableReason: String?
    /// The facts the CoreDisplay info dictionary carries.
    public var panel: DiagnosticGroup?
    /// The decoded DPCD registers, when a dump was read.
    public var dpcd: DiagnosticGroup?
    /// The DisplayPort link facts.
    public var link: DiagnosticGroup?
    /// The connection facts.
    public var connection: DiagnosticGroup?

    public init(
        edid: DisplayEDIDSummary? = nil,
        edidUnavailableReason: String? = nil,
        panel: DiagnosticGroup? = nil,
        dpcd: DiagnosticGroup? = nil,
        link: DiagnosticGroup? = nil,
        connection: DiagnosticGroup? = nil
    ) {
        self.edid = edid
        self.edidUnavailableReason = edidUnavailableReason
        self.panel = panel
        self.dpcd = dpcd
        self.link = link
        self.connection = connection
    }
}
