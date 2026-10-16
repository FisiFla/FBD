import CoreGraphics

enum PanelSizing {
    static let minimumHeight: CGFloat = 120
    static func height(content: CGFloat, screenVisibleHeight: CGFloat) -> CGFloat {
        let cap = (screenVisibleHeight * FBDTheme.maxHeightFraction).rounded(.down)
        return min(max(content, minimumHeight), cap)
    }
}
