import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: UsageModel
    @EnvironmentObject private var updater: AppUpdater
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var launchAtLogin: LaunchAtLoginModel

    init(launchAtLogin: LaunchAtLoginModel? = nil) {
        _launchAtLogin = StateObject(wrappedValue: launchAtLogin ?? LaunchAtLoginModel())
    }

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
            }

            Section {
                Toggle(isOn: launchAtLoginBinding) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at login")
                                .font(AppTheme.font(size: 13, weight: .medium))
                            Text("Open automatically when you log in")
                                .font(AppTheme.font(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        SettingsSymbolIcon(systemName: "power")
                    }
                }
                .toggleStyle(.switch)
                .accessibilityHint(launchAtLogin.accessibilityHint)

                if launchAtLogin.status == .requiresApproval {
                    Button("Open Login Items…") {
                        launchAtLogin.openLoginItemsSettings()
                    }
                }
            } header: {
                Text("General")
            } footer: {
                if let footer = launchAtLogin.footer {
                    Text(footer)
                }
            }

            Section {
                HStack(alignment: .center, spacing: 10) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Version \(updater.currentVersion)")
                                .font(AppTheme.font(size: 13, weight: .medium))
                                .monospacedDigit()
                            Text(updater.statusLine)
                                .font(AppTheme.font(size: 11))
                                .foregroundStyle(statusColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        SettingsSymbolIcon(systemName: "arrow.clockwise")
                    }

                    Spacer(minLength: 8)

                    Button(updater.buttonTitle) {
                        updater.performButtonAction()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .appControlFont(size: 11)
                    .disabled(updater.isBusy)
                }

                if let notes = updater.availableRelease?.displayNotes {
                    Text(notes)
                        .font(AppTheme.font(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(isOn: $updater.automaticallyChecks) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check automatically")
                            .font(AppTheme.font(size: 13, weight: .medium))
                        Text("Look for GitHub releases once a day")
                            .font(AppTheme.font(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: $updater.automaticallyInstalls) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Install automatically")
                            .font(AppTheme.font(size: 13, weight: .medium))
                        Text("Replace the app in Applications when a release is published")
                            .font(AppTheme.font(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            } header: {
                Text("Updates")
            }
        }
        .formStyle(.grouped)
        .frame(width: 448)
        .environment(\.font, AppTheme.font(size: 13))
        .background(SettingsWindowSpacePin())
        .onAppear {
            launchAtLogin.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                launchAtLogin.refresh()
            }
        }
    }

    private var statusColor: Color {
        switch updater.state {
        case .failed:
            return .orange
        case .available:
            return .accentColor
        default:
            return .secondary
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
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

private struct SettingsSymbolIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 22, height: 22)
            .foregroundStyle(.secondary)
    }
}
