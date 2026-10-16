import FBDCore
import SwiftUI

/// Plain-language names for `ProtectedProperties`, for everything the user reads.
///
/// `ProtectedProperties.ordered` carries the CLI vocabulary (`refreshRate`, `hdrMode`, …), which
/// is a stable identifier, not copy. Each label is a literal in `englishLabel(for:)` so the
/// localisation drift test can see it.
enum ProtectedPropertyLabels {
    /// Every protectable property, in apply order.
    static let ordered: [ProtectedProperties] = ProtectedProperties.ordered.map(\.property)

    static func englishLabel(for property: ProtectedProperties) -> String {
        switch property {
        case .resolution: return "Resolution"
        case .refreshRate: return "Refresh rate"
        case .brightness: return "Brightness"
        case .preset: return "XDR preset"
        case .hdrMode: return "HDR mode"
        case .mainStatus: return "Main display"
        case .rotation: return "Rotation"
        case .colourProfile: return "Colour profile"
        default: return ""
        }
    }

    static func label(for property: ProtectedProperties) -> LocalizedStringKey {
        LocalizedStringKey(englishLabel(for: property))
    }

    /// The translated labels of the properties in `set`, in apply order, as one string.
    static func list(_ set: ProtectedProperties) -> String {
        ordered.filter { set.contains($0) }
            .map { NSLocalizedString(englishLabel(for: $0), comment: "") }
            .joined(separator: ", ")
    }
}
