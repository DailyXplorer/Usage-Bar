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
            GroupedFormHeaderAlignmentAnchor()

            Section {
                ForEach(LimitBucket.Provider.allCases) { provider in
                    Toggle(isOn: visibility(for: provider)) {
                        Label {
                            Text(provider.title)
                                .font(AppTheme.font(size: 13, weight: .medium))
                        } icon: {
                            SettingsProviderIcon(provider: provider)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(isLastEnabled(provider))
                    .accessibilityHint(hint(for: provider))
                }
            } header: {
                SettingsSectionHeader(title: "Visible plans")
            }

            Section {
                Toggle(isOn: launchAtLoginBinding) {
                    Label {
                        Text("Launch at login")
                            .font(AppTheme.font(size: 13, weight: .medium))
                    } icon: {
                        SettingsSymbolIcon(systemName: "power")
                    }
                }
                .toggleStyle(.switch)
                .accessibilityHint(launchAtLogin.accessibilityHint)

                if launchAtLogin.status == .requiresApproval {
                    AppBorderedButton(title: "Open Login Items…") {
                        launchAtLogin.openLoginItemsSettings()
                    }
                }
            } header: {
                SettingsSectionHeader(title: "General")
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
                            if let statusLine = updater.statusLine {
                                Text(statusLine)
                                    .font(AppTheme.font(size: 11))
                                    .foregroundStyle(statusColor)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } icon: {
                        SettingsSymbolIcon(systemName: "arrow.clockwise")
                    }

                    Spacer(minLength: 8)

                    AppBorderedButton(title: updater.buttonTitle) {
                        updater.performButtonAction()
                    }
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
                    Text("Check automatically")
                        .font(AppTheme.font(size: 13, weight: .medium))
                }
                .toggleStyle(.switch)

                Toggle(isOn: $updater.automaticallyInstalls) {
                    Text("Install automatically")
                        .font(AppTheme.font(size: 13, weight: .medium))
                }
                .toggleStyle(.switch)
            } header: {
                SettingsSectionHeader(title: "Updates")
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

private struct GroupedFormHeaderAlignmentAnchor: View {
    var body: some View {
        Section {
            Color.clear
                .frame(height: 0)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
        }
        .listSectionSeparator(.hidden)
        .accessibilityHidden(true)
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
