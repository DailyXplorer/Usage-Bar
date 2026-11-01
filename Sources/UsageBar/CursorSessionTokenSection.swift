import SwiftUI

struct CursorSessionTokenActions {
    var hasToken: () async -> Bool
    var save: (String) async -> Bool
    var remove: () async -> Bool

    static let keychain = CursorSessionTokenActions(
        hasToken: { await CursorSessionTokenStore.shared.hasToken() },
        save: { await CursorSessionTokenStore.shared.save($0) },
        remove: { await CursorSessionTokenStore.shared.remove() }
    )
}

struct CursorSessionTokenSection: View {
    static let helpText = "Paste the WorkosCursorSessionToken cookie from cursor.com. It stays in your Keychain."

    @EnvironmentObject private var model: UsageModel
    @State private var draft = ""
    @State private var hasSavedToken: Bool
    @State private var rejected = false
    @State private var userActed = false
    private let actions: CursorSessionTokenActions

    init(actions: CursorSessionTokenActions = .keychain, hasSavedToken: Bool = false) {
        self.actions = actions
        _hasSavedToken = State(initialValue: hasSavedToken)
    }

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 10) {
                SecureField(
                    "Cursor session token",
                    text: $draft,
                    prompt: Text(hasSavedToken ? "Saved in Keychain" : "Paste token")
                )
                .textFieldStyle(.roundedBorder)
                .font(AppTheme.font(size: 12))
                .onSubmit(save)
                .accessibilityLabel("Cursor session token")

                if draft.isEmpty && hasSavedToken {
                    AppBorderedButton(title: "Remove", action: remove)
                } else {
                    AppBorderedButton(title: "Save", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } header: {
            SettingsSectionHeader(title: "Cursor")
        } footer: {
            Text(rejected ? "Usage Bar couldn’t update the Keychain. Try again, or allow access when macOS asks." : Self.helpText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            let saved = await actions.hasToken()
            if !userActed {
                hasSavedToken = saved
            }
        }
    }

    private func save() {
        let value = draft
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        userActed = true
        Task {
            let saved = await actions.save(value)
            rejected = !saved
            if saved {
                draft = ""
                hasSavedToken = true
                model.refreshNow(force: true)
            }
        }
    }

    private func remove() {
        userActed = true
        Task {
            let removed = await actions.remove()
            rejected = !removed
            if removed {
                hasSavedToken = false
                model.refreshNow(force: true)
            }
        }
    }
}
