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

    /// `in` matches SwiftUI's `Slider(value:in:)` argument shape.
    init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...1,
        zoneFraction: Double? = nil,
        accessibilityLabel: String,
        valueText: @escaping (Double) -> String
    ) {
        self._value = value
        self.range = range
        self.zoneFraction = zoneFraction
        self.accessibilityLabel = accessibilityLabel
        self.valueText = valueText
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
        GeometryReader { geo in
            let width = geo.size.width
            let x = fraction * width
            let zoneX = (zoneFraction.map { min(max($0, 0), 1) } ?? 1) * width

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.secondary.opacity(0.22))
                // Fill: accent up to the boost zone, boost tint beyond.
                HStack(spacing: 0) {
                    Capsule()
                        .fill(Color.accentColor.gradient)
                        .frame(width: max(x, 0))
                }
                .frame(width: max(x, 0), alignment: .leading)
                if let zoneFraction, zoneFraction > 0, zoneFraction < 1 {
                    // Boost-zone tint (the XDR region past the divider).
                    Capsule()
                        .fill(Color.orange.opacity(0.85))
                        .frame(width: max(x - zoneX, 0))
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
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: isDragging ? 3 : 2, y: isDragging ? 1.5 : 1)
                    .frame(width: 15, height: 15)
                    .scaleEffect(thumbScale)
                    .offset(x: x - 7.5)
            }
            .frame(height: 15)
            .contentShape(Rectangle().inset(by: -6))
            .gesture(dragGesture(width: width))
        }
        .frame(height: 22)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : FBDTheme.animationFast) {
                isHovering = hovering
            }
        }
        .focusable()
        .focused($isFocused)
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

    private var thumbScale: CGFloat {
        if reduceMotion { return 1 }
        return isDragging || isFocused ? 1.2 : (isHovering ? 1.1 : 1)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                isDragging = true
                applyFraction(gesture.location.x / width)
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
