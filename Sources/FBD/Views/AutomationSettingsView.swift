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
    /// The most recent manual run, shown under its own row. Running from here
    /// rather than deferring to `fbdcli` is also what lets a notification rule
    /// work: the CLI has no bundle identity and no notification authorisation.
    @State private var lastRun: AutomationRunRecord?

    @State private var scope = ""                 // "" = any display
    @State private var event = AutomationEvent.displayConnected
    @State private var kind = AutomationActionKind.shellScript
    @State private var payload = ""

    var body: some View {
        SettingsGroup {
            Text("Runs your command when a display connects or disconnects, or when the system sleeps or wakes. Shell rules execute as /bin/zsh -c, with FBD_EVENT and FBD_DISPLAY_NAME in the environment — add only commands you trust. FBD_DISPLAY_NAME comes from the monitor itself, so treat it as untrusted input and always quote it in scripts. Nothing runs until you add a rule.")
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: FBDTheme.spacingM) {
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
                    // Three views rather than one interpolated string: composing them into a single
                    // Text would look up a format key ("%@ · %@ · %@") that has no literal text in it,
                    // which nothing can verify and no translator can meaningfully reorder.
                    HStack(spacing: 4) {
                        switch scopeLabel(rule) {
                        case .anyDisplay:
                            Text("Any display")
                        case .named(let name):
                            // A display's name is the user's own data, so it is shown verbatim.
                            Text(verbatim: name)
                        }
                        Text("·").foregroundStyle(.secondary)
                        Text(eventLabel(rule.event))
                        Text("·").foregroundStyle(.secondary)
                        Text(kindLabel(rule.kind))
                    }
                    .font(.callout)
                    Text(rule.payload)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
                // Run it now. For a manual control this is the control's action; for
                // an event rule it is the "try it without waiting" path.
                Button {
                    lastRun = controller.runSynchronously(rule)
                    tick += 1
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(rule.event == .manual ? "Run this control now" : "Run this rule now")
                .accessibilityLabel(rule.event == .manual ? "Run control" : "Run rule")
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

            if let lastRun, lastRun.ruleID == rule.id {
                Text(describe(lastRun))
                    .font(.caption.monospaced())
                    .foregroundStyle(lastRun.succeeded ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What a run did, in one line — the point being that a rule which did nothing
    /// visible still says so.
    private func describe(_ record: AutomationRunRecord) -> String {
        let output = record.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = record.timedOut ? "timed out" : "exit \(record.exitCode)"
        return output.isEmpty ? status : "\(status) — \(output)"
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: FBDTheme.spacingS) {
            HStack(spacing: FBDTheme.spacingS) {
                Picker("Display", selection: $scope) {
                    Text("Any display").tag("")
                    ForEach(displays, id: \.identityKey) { display in
                        Text(display.name).tag(display.identityKey)
                    }
                }
                .labelsHidden()
                Picker("Event", selection: $event) {
                    ForEach(AutomationEvent.allCases, id: \.self) { option in
                        Text(eventLabel(option)).tag(option)
                    }
                }
                .labelsHidden()
                Picker("Action", selection: $kind) {
                    ForEach(AutomationActionKind.allCases, id: \.self) { option in
                        Text(kindLabel(option)).tag(option)
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
    /// The rule's scope, as a value rather than a string: the placeholder is a key, while a display's
    /// name is the user's own data and has to be shown as it is.
    private enum ScopeLabel {
        case anyDisplay
        case named(String)
    }

    private func scopeLabel(_ rule: AutomationRule) -> ScopeLabel {
        guard !rule.displayIdentityKey.isEmpty else { return .anyDisplay }
        return .named(
            displays.first { $0.identityKey == rule.displayIdentityKey }?.name
                ?? rule.displayIdentityKey
        )
    }

    /// The event as the UI shows it.
    ///
    /// A `switch` here rather than `event.label`: that property is also handed to shell rules as
    /// `FBD_EVENT_LABEL`, which is a **script contract** — a rule matching on "display connected"
    /// would break the moment someone ran FBD in another language. The model keeps its English
    /// accessor; only the UI localises.
    private func eventLabel(_ event: AutomationEvent) -> LocalizedStringKey {
        switch event {
        case .displayConnected: return "display connected"
        case .displayDisconnected: return "display disconnected"
        case .systemSleep: return "system sleep"
        case .systemWake: return "system wake"
        case .manual: return "run manually"
        }
    }

    /// Likewise for the action kind, whose `token` is the spelling the CLI accepts.
    private func kindLabel(_ kind: AutomationActionKind) -> LocalizedStringKey {
        switch kind {
        case .shellScript: return "shell"
        case .url: return "url"
        case .notification: return "notify"
        }
    }
}
