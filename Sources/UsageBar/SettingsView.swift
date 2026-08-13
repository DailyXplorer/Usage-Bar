import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: UsageModel

    var body: some View {
        Form {
            Section {
                ForEach(LimitBucket.Provider.allCases) { provider in
                    Toggle(isOn: visibility(for: provider)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.title)
                                    .font(AppTheme.font(size: 13, weight: .medium))
                                Text(provider.subtitle)
                                    .font(AppTheme.font(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            SettingsProviderIcon(provider: provider)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(isLastEnabled(provider))
                    .accessibilityHint(hint(for: provider))
                }
            } header: {
                Text("Visible plans")
            } footer: {
                Text("These plans appear in the menu bar and in the popover. Cursor in the menu bar shows the Grok and Composer pool.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 448)
        .environment(\.font, AppTheme.font(size: 13))
    }

    private func visibility(for provider: LimitBucket.Provider) -> Binding<Bool> {
        Binding(
            get: { model.isVisibleInMenuBar(provider) },
            set: { model.setVisibleInMenuBar(provider, visible: $0) }
        )
    }

    private func isLastEnabled(_ provider: LimitBucket.Provider) -> Bool {
        model.isVisibleInMenuBar(provider) && !model.canHideMenuBarProvider
    }

    private func hint(for provider: LimitBucket.Provider) -> String {
        if isLastEnabled(provider) {
            return "At least one plan must stay in the menu bar"
        }
        return "Show \(provider.title) in the menu bar"
    }
}

private struct SettingsProviderIcon: View {
    let provider: LimitBucket.Provider

    var body: some View {
        Group {
            if let image = AppTheme.logo(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 11))
            }
        }
        .frame(width: 22, height: 22)
        .foregroundStyle(.secondary)
    }
}
