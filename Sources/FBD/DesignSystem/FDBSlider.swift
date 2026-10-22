import SwiftUI

/// Custom macOS slider: rounded track with a gradient fill, a floating
/// thumb, optional "boost zone" marker (hardware → XDR), hover/active
/// micro-animations, and full keyboard + VoiceOver accessibility.
///
/// macOS-13-compatible: no iOS 14+ slider-tracking APIs; the track is a
/// DragGesture over a GeometryReader.
struct FDBSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Fraction (0...1) where the boosted zone begins (e.g. hardware → XDR).
    /// The fill past this point uses the boost tint.
    let zoneFraction: Double?
    let accessibilityLabel: String
    let valueText: (Double) -> String
    /// SF Symbols shown either side of the track; `nil` hides them.
    let endSymbols: (String, String)?

    static let trackHeight: CGFloat = 6
    static let thumbWidth: CGFloat = 28
    static let thumbHeight: CGFloat = 20

    /// The live value bubble is only shown while the thumb is being dragged.
    static func showsValueOverlay(isDragging: Bool) -> Bool { isDragging }

    /// `in` matches SwiftUI's `Slider(value:in:)` argument shape.
    init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...1,
        zoneFraction: Double? = nil,
        accessibilityLabel: String,
        valueText: @escaping (Double) -> String,
        endSymbols: (String, String)? = ("sun.min", "sun.max")
    ) {
        self._value = value
        self.range = range
        self.zoneFraction = zoneFraction
        self.accessibilityLabel = accessibilityLabel
        self.valueText = valueText
        self.endSymbols = endSymbols
    }

    @State private var isHovering = false
    @State private var isDragging = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let stepCount = 20.0

    private var fraction: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    private var step: Double {
        (range.upperBound - range.lowerBound) / Self.stepCount
    }

    var body: some View {
        HStack(spacing: FBDTheme.spacingM) {
            if let endSymbols { endImage(endSymbols.0) }
            track
            if let endSymbols { endImage(endSymbols.1) }
        }
        .frame(height: 22)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : FBDTheme.animationFast) {
                isHovering = hovering
            }
        }
        .focusable()
        .focused($isFocused)
        .modifier(WithoutSystemFocusEffect())
        .onMoveCommand { direction in
            applyKeyboardDirection(direction)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(valueText(value))
        // The adjustable action is what makes VoiceOver announce and drive
        // this control as adjustable (macOS has no slider trait).
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: increment(by: step)
            case .decrement: decrement(by: step)
            @unknown default: break
            }
        }
    }

    private func endImage(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private var thumb: some View {
        thumbBody
            .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: isDragging ? 3 : 2, y: isDragging ? 1.5 : 1)
            .frame(width: Self.thumbWidth, height: Self.thumbHeight)
            .scaleEffect(thumbScale)
    }

    /// A glass pill on macOS 26+, tinted light so it stays clearly visible on the track (an
    /// opaque fill under the glass would hide it); the plain white pill otherwise.
    @ViewBuilder
    private var thumbBody: some View {
        if FBDGlass.isAvailable {
            Capsule()
                .fill(Color.clear)
                .fbdGlass(in: Capsule(), tint: .white.opacity(0.55))
        } else {
            Capsule().fill(.white)
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let half = Self.thumbWidth / 2
            let usable = max(width - Self.thumbWidth, 1)
            let x = half + fraction * usable
            let zoneX = half + (zoneFraction.map { min(max($0, 0), 1) } ?? 1) * usable

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(height: Self.trackHeight)
                // Fill: accent up to the boost zone, boost tint beyond.
                HStack(spacing: 0) {
                    Capsule()
                        .fill(Color.accentColor.gradient)
                        .frame(width: max(x, 0))
                }
                .frame(width: max(x, 0), height: Self.trackHeight, alignment: .leading)
                if let zoneFraction, zoneFraction > 0, zoneFraction < 1 {
                    // Boost-zone tint (the XDR region past the divider).
                    Capsule()
                        .fill(Color.orange.opacity(0.85))
                        .frame(width: max(x - zoneX, 0), height: Self.trackHeight)
                        .offset(x: zoneX)
                }
                // Zone divider tick.
                if let zoneFraction, zoneFraction > 0, zoneFraction < 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 1, height: 10)
                        .offset(x: zoneX - 0.5)
                }
                // Thumb.
                thumb
                    .offset(x: x - half)
            }
            .frame(height: Self.thumbHeight)
            .contentShape(Rectangle().inset(by: -6))
            .gesture(dragGesture(width: width))
            .overlay(alignment: .top) {
                if Self.showsValueOverlay(isDragging: isDragging) {
                    Text(valueText(value))
                        .font(FBDTheme.Font.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .fbdGlass(in: Capsule())
                        .offset(y: -22)
                }
            }
        }
        .frame(height: 22)
    }

    private var thumbScale: CGFloat {
        if reduceMotion { return 1 }
        return isDragging || isFocused ? 1.2 : (isHovering ? 1.1 : 1)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                isDragging = true
                applyFraction((gesture.location.x - Self.thumbWidth / 2) / max(width - Self.thumbWidth, 1))
            }
            .onEnded { _ in
                isDragging = false
            }
    }

    private func applyFraction(_ raw: CGFloat) {
        let clamped = min(max(Double(raw), 0), 1)
        value = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
    }

    private func applyKeyboardDirection(_ direction: MoveCommandDirection) {
        switch direction {
        case .left, .down: decrement(by: step)
        case .right, .up: increment(by: step)
        @unknown default: break
        }
    }

    private func increment(by amount: Double) {
        withAnimation(reduceMotion ? nil : FBDTheme.animationFast) {
            value = min(value + amount, range.upperBound)
        }
    }

    private func decrement(by amount: Double) {
        withAnimation(reduceMotion ? nil : FBDTheme.animationFast) {
            value = max(value - amount, range.lowerBound)
        }
    }
}

/// Drops macOS's default focus effect (the blue ring SwiftUI draws around a
/// focused view).
///
/// The slider's focusable view is the whole row — the sun icons included — so
/// the ring reads as a stray border drawn around the control rather than as a
/// focus indicator. The thumb already grows when the control has focus, which
/// is the indicator that belongs to this design.
///
/// `focusEffectDisabled()` needs macOS 14; FBD still supports macOS 13, where
/// the modifier does not exist and the system effect is left alone.
private struct WithoutSystemFocusEffect: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}
