import CoreGraphics

/// Where the popover is. One level below home, except `allModes` (below its display).
enum PanelRoute: Hashable {
    case home
    case display(CGDirectDisplayID)
    case allModes(CGDirectDisplayID)
    case virtualScreens
    case groups
    case newPreset(CGDirectDisplayID)

    var parent: PanelRoute? {
        switch self {
        case .home: return nil
        case .allModes(let id): return .display(id)
        default: return .home
        }
    }

    var displayID: CGDirectDisplayID? {
        switch self {
        case .display(let id), .allModes(let id), .newPreset(let id): return id
        default: return nil
        }
    }
}
