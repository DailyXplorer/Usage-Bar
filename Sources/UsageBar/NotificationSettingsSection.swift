import SwiftUI

struct NotificationSettingsSection: View {
    static let deniedMessage = "Notifications are off for Usage Bar in System Settings."

    @EnvironmentObject private var alerts: UsageAlertCenter
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section {
            Toggle(isOn: $alerts.preferences.warnsWhenLow) {
                Text("Notify when a limit runs low")
                    .font(AppTheme.font(size: 13, weight: .medium))
            }
            .toggleStyle(.switch)

            Picker(selection: $alerts.preferences.warnAtPercentLeft) {
                ForEach(UsageAlertPreferences.warnAtChoices, id: \.self) { percent in
                    Text("\(percent)% left").tag(percent)
                }
            } label: {
                Text("Warn at")
                    .font(AppTheme.font(size: 13, weight: .medium))
            }
            .disabled(!alerts.preferences.warnsWhenLow)

            Toggle(isOn: $alerts.preferences.notifiesOnReset) {
                Text("Notify when a limit resets")
                    .font(AppTheme.font(size: 13, weight: .medium))
            }
            .toggleStyle(.switch)

            if alerts.permission == .denied {
                HStack(alignment: .center, spacing: 10) {
                    Text(Self.deniedMessage)
                        .font(AppTheme.font(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    AppBorderedButton(title: "Open System Settings") {
                        alerts.openNotificationSettings()
                    }
                }
            }
        } header: {
            SettingsSectionHeader(title: "Notifications")
        }
        .task {
            await alerts.refreshPermission()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await alerts.refreshPermission() }
            }
        }
    }
}
