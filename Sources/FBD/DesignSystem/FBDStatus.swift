import SwiftUI

/// A short-lived, inline outcome for a control that does real work.
///
/// FBD's operations are mostly fast but not instant: a DDC read is a round trip
/// to the monitor, a mode apply goes through SkyLight, and both can take
/// hundreds of milliseconds or fail outright. Before this the UI showed nothing
/// in either case, so an in-flight probe and a refused write looked identical to
/// a dead button — and the natural reaction was to click again, which queues
/// another DDC command on the display.
///
/// Deliberately **inline rather than an alert**: these are per-action,
/// recoverable outcomes, and a modal for "the display refused that write" would
/// be far more disruptive than the failure itself.
enum FBDStatus: Equatable {
    case working(String)
    case failed(String)
    case succeeded(String)

    var message: String {
        switch self {
        case .working(let message), .failed(let message), .succeeded(let message):
            return message
        }
    }

    /// True once the operation has finished, either way. A finished status is
    /// worth keeping on screen; an in-flight one is replaced by the next action.
    var isTerminal: Bool {
        if case .working = self { return false }
        return true
    }
}

/// One-line renderer for `FBDStatus`, sized to sit under the control that
/// produced it.
struct FBDStatusLine: View {
    let status: FBDStatus

    var body: some View {
        HStack(spacing: FBDTheme.spacingXS) {
            switch status {
            case .working(let message):
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(message)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
            case .succeeded(let message):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(message)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        // Announced as one phrase ("Reading capabilities…") instead of three
        // fragments, and failures are what must not be missed.
        .accessibilityElement(children: .combine)
    }
}
