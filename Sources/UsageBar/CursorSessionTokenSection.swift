import SwiftUI

struct CursorSessionTokenActions {
    var hasToken: () async -> Bool
    var save: (String) async -> CursorSessionTokenStore.SaveOutcome
    var remove: () async -> Bool

    static let keychain = CursorSessionTokenActions(
        hasToken: { await CursorSessionTokenStore.shared.hasToken() },
        save: { await CursorSessionTokenStore.shared.save($0) },
        remove: { await CursorSessionTokenStore.shared.remove() }
    )
}

struct CursorSessionTokenSection: View {
    static let helpText = "Sign in at cursor.com in your browser, open its developer tools, and copy the WorkosCursorSessionToken cookie under Cookies for cursor.com. It stays in your Keychain."

    static func message(for outcome: CursorSessionTokenStore.SaveOutcome?) -> String {
        switch outcome {
        case .invalid(.unrecognized):
            return "That isn’t a Cursor session token. Copy the WorkosCursorSessionToken cookie value from cursor.com."
        case .invalid(.expired):
            return "That Cursor session token has expired. Sign in at cursor.com again and copy the new cookie."
        case .keychainFailed:
            return keychainFailureText
        case .saved, nil:
            return helpText
        }
    }

    private static let keychainFailureText = "Usage Bar couldn’t update the Keychain. Try again, or allow access when macOS asks."

    @EnvironmentObject private var model: UsageModel
    @State private var draft = ""
    @State private var hasSavedToken: Bool
    @State private var outcome: CursorSessionTokenStore.SaveOutcome?
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
            Text(Self.message(for: outcome))
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
            let result = await actions.save(value)
            outcome = result
            if result == .saved {
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
            outcome = removed ? nil : .keychainFailed
            if removed {
                hasSavedToken = false
                model.refreshNow(force: true)
            }
        }
    }
}
