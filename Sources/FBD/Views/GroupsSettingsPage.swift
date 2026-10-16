import FBDCore
import SwiftUI

/// Display groups, their activation policy and their synchronisation filters.
@MainActor
struct GroupsSettingsPage: View {
    @State private var controller = DisplayGroupsController()
    @State private var groups: [DisplayGroup] = []
    @State private var newGroupName = ""
    @State private var groupPendingDelete: DisplayGroup?

    var body: some View {
        SettingsPane("Groups") {
            SettingsGroup {
                Text("Display groups let one operation affect several displays: brightness synchronisation, UI scale matching and layout management.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: FBDTheme.spacingM) {
                    TextField("New group name", text: $newGroupName)
                    Button("Create") {
                        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        controller.createGroup(name: name)
                        newGroupName = ""
                        reload()
                    }
                    .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if groups.isEmpty {
                    Text("No groups yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Display groups", systemImage: "rectangle.3.group")
            }

            ForEach(groups) { group in
                SettingsGroup {
                    Toggle("Synchronise this group", isOn: enabledBinding(group))
                    Text("When off, group operations are skipped entirely for this group.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Activate when", selection: policyBinding(group)) {
                        ForEach(GroupActivationPolicy.allCases, id: \.self) { policy in
                            Text(label(for: policy)).tag(policy)
                        }
                    }
                    Text(policyCaption(controller.activationPolicy(forGroup: group.id)))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: FBDTheme.spacingM) {
                        Text("\(group.displayIDs.count) display\(group.displayIDs.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Sync now") { syncNow(group) }
                            .controlSize(.small)
                            .disabled(group.displayIDs.count < 2 || !controller.isEnabled(groupID: group.id))
                            .help("Propagate the first connected member's current brightness to the rest of the group.")
                        Button("Mirror") { _ = controller.mirror(inGroup: group.id) }
                            .controlSize(.small)
                            .disabled(group.displayIDs.count < 2)
                        Button("Unmirror") { _ = controller.unmirror(inGroup: group.id) }
                            .controlSize(.small)
                        Button("Delete", role: .destructive) { groupPendingDelete = group }
                        .controlSize(.small)
                    }
                } header: {
                    Label(group.name, systemImage: "rectangle.3.group")
                }
            }
        }
        .onAppear(perform: reload)
        .fbdConfirmation(
            "Delete this group?",
            isPresented: Binding(
                get: { groupPendingDelete != nil },
                set: { if !$0 { groupPendingDelete = nil } }
            ),
            confirm: "Delete",
            message: "The displays themselves are not affected."
        ) {
            if let group = groupPendingDelete {
                controller.deleteGroup(id: group.id)
                reload()
            }
            groupPendingDelete = nil
        }
    }

    private func reload() { groups = controller.groups }

    private func enabledBinding(_ group: DisplayGroup) -> Binding<Bool> {
        Binding(
            get: { controller.isEnabled(groupID: group.id) },
            set: { controller.setEnabled($0, forGroup: group.id) }
        )
    }

    private func policyBinding(_ group: DisplayGroup) -> Binding<GroupActivationPolicy> {
        Binding(
            get: { controller.activationPolicy(forGroup: group.id) },
            set: { controller.setActivationPolicy($0, forGroup: group.id) }
        )
    }

    /// Propagate the group's reference display's current brightness to the rest
    /// of the group, through the same tested planner an explicit value uses.
    ///
    /// This was the missing half of group sync: the enabled flag and the
    /// activation policy were configurable here, but nothing in the app could
    /// actually trigger a sync — only `fbdcli config group-sync` could.
    private func syncNow(_ group: DisplayGroup) {
        let displays = DisplayController.shared.displays
        // Read every member's brightness once, up front, so the closure handed to
        // the controller is a plain lookup: it touches no DDC bus and no actor.
        var brightnessByID: [CGDirectDisplayID: Double] = [:]
        for display in displays {
            if let value = display.brightness ?? DisplayController.shared.getBrightness(for: display) {
                brightnessByID[display.id] = value
            }
        }
        guard let reading = controller.syncValue(
            inGroup: group.id,
            connectedIDs: Set(displays.map { $0.id }),
            currentBrightness: { brightnessByID[$0] }
        ) else {
            return
        }
        _ = controller.applyGroupSync(
            reading.value,
            inGroup: group.id,
            controller: .shared,
            referenceDisplayID: reading.sourceDisplayID
        )
    }

    private func label(for policy: GroupActivationPolicy) -> String {
        switch policy {
        case .always: return "Always"
        case .allMembersPresent: return "All members present"
        case .anyMembersPresent: return "Any member present"
        case .anyTwoMembersPresent: return "Any two members present"
        case .anySyncSourceWithTargetMembersPresent: return "A sync source and target present"
        }
    }

    private func policyCaption(_ policy: GroupActivationPolicy) -> String {
        switch policy {
        case .always: return "The group is always active."
        case .allMembersPresent: return "The group is active only while every member is connected."
        case .anyMembersPresent: return "The group is active while at least one member is connected."
        case .anyTwoMembersPresent: return "The group is active while at least two members are connected."
        case .anySyncSourceWithTargetMembersPresent: return "The group is active while both a sync source and a sync target are connected."
        }
    }
}
