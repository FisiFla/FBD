import FBDCore
import SwiftUI

/// Settings section for **per-display event automation**.
///
/// Its own view because the section owns real state (the rule list and the
/// add-rule form) and because it has to be explicit about what will run: each
/// row shows the payload verbatim, and shell rules say outright that they go
/// through `/bin/zsh -c`. A rule exists only if the user adds one, so the
/// section is opt-in by construction.
@MainActor
struct AutomationSettingsView: View {
    /// Local instance for editing. It shares the persisted rule store with the
    /// app's observing instance (which re-reads before every event), so a rule
    /// added here takes effect without a restart.
    @State private var controller = DisplayAutomationController()
    /// The controller is not an `ObservableObject`, so mutations bump this to
    /// re-render the list.
    @State private var tick = 0

    @State private var scope = ""                 // "" = any display
    @State private var event = AutomationEvent.displayConnected
    @State private var kind = AutomationActionKind.shellScript
    @State private var payload = ""

    var body: some View {
        Section {
            Text("Runs your command when a display connects or disconnects, or when the system sleeps or wakes. Shell rules execute as /bin/zsh -c, with FBD_EVENT and FBD_DISPLAY_NAME in the environment — add only commands you trust. Nothing runs until you add a rule.")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(rules) { rule in
                ruleRow(rule)
            }
            if rules.isEmpty {
                Text("No automation rules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            addRow
            if event.isSystemEvent, !scope.isEmpty {
                Text("System events only fire for rules scoped to \"Any display\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Automation", systemImage: "bolt.horizontal.circle")
        }
    }

    // MARK: - Rows

    private func ruleRow(_ rule: AutomationRule) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // A real (visually hidden) label: `Toggle("")` leaves VoiceOver with
            // no name for this control at all.
            Toggle("Enabled", isOn: Binding(
                get: { rule.enabled },
                set: { enabled in
                    _ = controller.setEnabled(enabled, ruleID: rule.id)
                    tick += 1
                }
            ))
            .labelsHidden()
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(scopeLabel(rule)) · \(rule.event.label) · \(rule.kind.token)")
                    .font(.callout)
                Text(rule.payload)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                _ = controller.removeRule(id: rule.id)
                tick += 1
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Remove this rule")
            .accessibilityLabel("Remove rule")
        }
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("Display", selection: $scope) {
                    Text("Any display").tag("")
                    ForEach(displays, id: \.identityKey) { display in
                        Text(display.name).tag(display.identityKey)
                    }
                }
                .labelsHidden()
                Picker("Event", selection: $event) {
                    ForEach(AutomationEvent.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                Picker("Action", selection: $kind) {
                    ForEach(AutomationActionKind.allCases, id: \.self) { option in
                        Text(option.token).tag(option)
                    }
                }
                .labelsHidden()
            }
            .controlSize(.small)

            TextField(kind == .shellScript ? "Shell command" : "URL", text: $payload)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())

            Button("Add rule") { addRule() }
                .controlSize(.small)
                .disabled(trimmedPayload.isEmpty)
        }
    }

    // MARK: - Actions and lookups

    private var trimmedPayload: String {
        payload.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addRule() {
        let body = trimmedPayload
        guard !body.isEmpty else { return }
        _ = controller.addRule(
            displayIdentityKey: scope,
            event: event,
            kind: kind,
            payload: body
        )
        payload = ""
        tick += 1
    }

    private var rules: [AutomationRule] {
        _ = tick
        return controller.allRules
    }

    private var displays: [Display] {
        DisplayController.shared.displays.filter(\.isOnline)
    }

    /// Name the rule's display where it is still connected, otherwise fall back
    /// to the stored identity (which is all a disconnected display leaves).
    private func scopeLabel(_ rule: AutomationRule) -> String {
        guard !rule.displayIdentityKey.isEmpty else { return "Any display" }
        return displays.first { $0.identityKey == rule.displayIdentityKey }?.name
            ?? rule.displayIdentityKey
    }
}
