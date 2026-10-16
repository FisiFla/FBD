import FBDCore
import SwiftUI

extension View {
    /// A destructive-action confirmation. `message` is optional; the action runs only when the
    /// user picks the destructive button.
    func fbdConfirmation(
        _ title: LocalizedStringKey,
        isPresented: Binding<Bool>,
        confirm: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        action: @escaping () -> Void
    ) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button(confirm, role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            if let message { Text(message) }
        }
    }

    /// The soft-disconnect confirmation shared by the panel row and the Settings card. Attach it
    /// to a view that is always present (not to the power button, which is hidden when
    /// "connect/disconnect" is off while the options menu can still request it).
    func fbdDisableDisplayConfirmation(isPresented: Binding<Bool>, display: Display) -> some View {
        fbdConfirmation(
            "Disable display?",
            isPresented: isPresented,
            confirm: "Disable",
            message: "Display will go dark until re-enabled."
        ) {
            _ = DisconnectController().setEnabled(false, displayID: display.id)
        }
    }
}
