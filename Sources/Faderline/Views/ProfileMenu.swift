import SwiftUI

enum ProfileDialog: String, Identifiable {
    case saveAs, rename, revert, delete
    var id: String { rawValue }
}

/// Contents of the app-level Profiles menu. ⌘0 recalls Default (no profile);
/// ⌘1–⌘9 recall the first nine profiles in list order.
struct ProfileMenuItems: View {
    let viewModel: MixerViewModel

    private var library: MixerProfileLibrary { viewModel.profileLibrary }

    var body: some View {
        Group {
            selectionItem(MixerProfileLibrary.defaultName, id: nil, shortcut: "0")
            ForEach(Array(library.profiles.enumerated()), id: \.element.id) { index, profile in
                selectionItem(profile.name, id: profile.id,
                              shortcut: index < 9 ? KeyEquivalent(Character(String(index + 1))) : nil)
            }
            Divider()
            Button(viewModel.hasActiveProfile ? "Save Profile" : "Save Profile…", action: viewModel.saveProfile)
                .keyboardShortcut("s")
                .disabled(!viewModel.canSaveProfile)
            Button("Save As…") { viewModel.profileDialog = .saveAs }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(viewModel.profilesUnavailable)
            Button("Rename…") { viewModel.profileDialog = .rename }
                .disabled(!viewModel.hasActiveProfile)
            Divider()
            Button("Revert to Saved…") { viewModel.profileDialog = .revert }
                .disabled(!viewModel.canRevertProfile)
            Button("Delete Profile…", role: .destructive) { viewModel.profileDialog = .delete }
                .disabled(!viewModel.hasActiveProfile)
        }
        .disabled(viewModel.profileDialog != nil)
    }

    private func selectionItem(_ title: String, id: UUID?, shortcut: KeyEquivalent?) -> some View {
        let edited = id != nil && id == library.activeID && viewModel.isProfileEdited
        return Toggle(title + (edited ? " — Edited" : ""), isOn: Binding(
            get: { library.activeID == id },
            set: { _ in viewModel.selectProfile(id) }
        ))
        .keyboardShortcut(shortcut.map { KeyboardShortcut($0) })
        .disabled(viewModel.profilesUnavailable)
    }
}

struct ProfileDialogView: View {
    @Environment(MixerViewModel.self) private var viewModel
    let dialog: ProfileDialog
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var activeName: String { viewModel.profileLibrary.active?.name ?? "" }
    private var isNaming: Bool { dialog == .saveAs || dialog == .rename }
    private var title: String {
        switch dialog {
        case .saveAs: "Save Profile As"
        case .rename: "Rename Profile"
        case .revert: "Revert to Saved?"
        case .delete: "Delete Profile?"
        }
    }
    private var actionTitle: String {
        switch dialog {
        case .saveAs: "Save"
        case .rename: "Rename"
        case .revert: "Revert"
        case .delete: "Delete"
        }
    }
    private var nameError: String? {
        viewModel.profileNameError(name, renaming: dialog == .rename)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            if isNaming {
                TextField("Profile name", text: $name)
                    .accessibilityLabel("Profile name")
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { if nameError == nil { submit() } }
                if let nameError {
                    Text(nameError).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(dialog == .revert
                     ? "Discard the working changes to “\(activeName)”? The saved mix will be restored."
                     : "Delete “\(activeName)” and its working changes? This cannot be undone.")
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error = viewModel.profileError {
                Text(error).font(.caption).foregroundStyle(MixerTheme.errorText)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { viewModel.profileDialog = nil }
                    .accessibilityLabel("Cancel")
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, role: isNaming ? nil : .destructive, action: submit)
                    .accessibilityLabel(actionTitle)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isNaming && nameError != nil)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear {
            name = dialog == .rename ? activeName : ""
            nameFocused = isNaming
        }
    }

    private func submit() {
        switch dialog {
        case .saveAs:
            if viewModel.saveProfileAs(name) { viewModel.profileDialog = nil }
        case .rename:
            if viewModel.renameProfile(name) { viewModel.profileDialog = nil }
        case .revert:
            viewModel.revertProfile()
            viewModel.profileDialog = nil
        case .delete:
            if let id = viewModel.profileLibrary.activeID { viewModel.deleteProfile(id) }
            viewModel.profileDialog = nil
        }
    }
}
