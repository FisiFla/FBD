import SwiftUI

/// One app-level place to surface an action that did not do what it said.
///
/// Several controls call a controller and discard the result: rotation returns an
/// optional, and mirror/unmirror return a `Bool`, and nothing looked at any of
/// them. A refusal was written to the log and nowhere else, so the control simply
/// appeared dead — the user clicked, the menu closed, and nothing happened.
///
/// A shared surface rather than per-view state, because these actions live in
/// **menus**, which dismiss on selection: a status line inside the menu would
/// never be on screen long enough to read. The banner sits under the panel's top
/// bar instead, where it is visible on either page.
@MainActor
final class FBDNotice: ObservableObject {
    static let shared = FBDNotice()

    @Published private(set) var message: String?

    private var clearTask: Task<Void, Never>?

    /// Report a failed action, replacing any current notice.
    ///
    /// Clears itself after a few seconds: the panel is a transient popover, so a
    /// notice that outlived the moment would be stale by the time it was read.
    func report(_ message: String) {
        self.message = message
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    func dismiss() {
        clearTask?.cancel()
        clearTask = nil
        message = nil
    }
}

/// Dismissible one-line banner for `FBDNotice`.
struct FBDNoticeBanner: View {
    @ObservedObject var notice: FBDNotice

    var body: some View {
        if let message = notice.message {
            HStack(spacing: FBDTheme.spacingS) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: FBDTheme.spacingS)
                Button {
                    notice.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .frame(minWidth: 20, minHeight: 20)
                .accessibilityLabel("Dismiss message")
            }
            .padding(.horizontal, FBDTheme.spacingM)
            .padding(.vertical, FBDTheme.spacingS)
            .background(
                RoundedRectangle(cornerRadius: FBDTheme.radiusInset, style: .continuous)
                    .fill(Color.orange.opacity(0.15))
            )
            .padding(.horizontal, FBDTheme.spacingM)
            .accessibilityElement(children: .combine)
        }
    }
}
