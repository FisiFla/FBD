import FBDCore
import SwiftUI

struct GroupsPage: View {
    @ObservedObject var model: PanelModel

    // Not a singleton: held here like the pre-revamp list view did. It is a plain class, so
    // `tick` forces a re-read after changes.
    private let controller = DisplayGroupsController()
    @State private var tick = 0

    @State private var newName = ""
    /// At most one group's policy list is open at a time.
    @State private var expandedGroupID: String?
    @State private var pendingDelete: DisplayGroup?

    var body: some View {
        let _ = tick  // dependency: re-evaluate after a mutation
        return VStack(alignment: .leading, spacing: FBDTheme.spacingXS) {
            ForEach(controller.groups) { group in
                groupRow(group)
                if expandedGroupID == group.id { policyList(group) }
            }
            if controller.groups.isEmpty {
                Text("No groups yet. Create one to sync brightness or mirror displays.")
                    .font(FBDTheme.Font.secondary)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, FBDTheme.spacingM)
            }
            HStack(spacing: FBDTheme.spacingM) {
                TextField("Group name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
                Button("New Group", action: create)
                    .fbdGlassButton()
                    .controlSize(.small)
                    .disabled(trimmedName.isEmpty)
            }
            .padding(.horizontal, FBDTheme.spacingM)
            .padding(.top, FBDTheme.spacingS)
        }
        .fbdConfirmation(
            "Delete this group?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            confirm: "Delete",
            message: "The displays themselves are not affected."
        ) {
            if let group = pendingDelete {
                controller.deleteGroup(id: group.id)
                if expandedGroupID == group.id { expandedGroupID = nil }
            }
            pendingDelete = nil
            changed()
        }
    }

    private func groupRow(_ group: DisplayGroup) -> some View {
        HStack(spacing: FBDTheme.spacingS) {
            FBDListRow(
                symbol: "square.grid.2x2",
                title: LocalizedStringKey(group.name),
                value: Self.memberCount(group.displayIDs.count),
                showsChevron: expandedGroupID != group.id
            ) {
                withAnimation(FBDTheme.animationFast) {
                    expandedGroupID = expandedGroupID == group.id ? nil : group.id
                }
            }
            Toggle("Enabled", isOn: Binding(
                get: { controller.isEnabled(groupID: group.id) },
                set: { controller.setEnabled($0, forGroup: group.id); changed() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            Button { pendingDelete = group } label: { Image(systemName: "trash") }
                .fbdGlassButton()
                .controlSize(.small)
                .accessibilityLabel("Delete")
        }
    }

    private func policyList(_ group: DisplayGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(GroupActivationPolicy.allCases, id: \.self) { policy in
                FBDListRow(
                    symbol: "circle", title: Self.label(for: policy),
                    isChecked: controller.activationPolicy(forGroup: group.id) == policy
                ) {
                    controller.setActivationPolicy(policy, forGroup: group.id)
                    changed()
                }
            }
        }
        .padding(.leading, FBDTheme.spacingL)
    }

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespaces) }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        controller.createGroup(name: trimmedName)
        newName = ""
        changed()
    }

    private func changed() {
        tick += 1
        model.refreshCounts()
    }

    static func memberCount(_ n: Int) -> String {
        n == 1 ? String(localized: "1 display") : String(localized: "\(n) displays")
    }

    static func label(for policy: GroupActivationPolicy) -> LocalizedStringKey {
        switch policy {
        case .always: return "Always"
        case .allMembersPresent: return "All members present"
        case .anyMembersPresent: return "Any member present"
        case .anyTwoMembersPresent: return "Any two members present"
        case .anySyncSourceWithTargetMembersPresent: return "A sync source and target present"
        }
    }
}
