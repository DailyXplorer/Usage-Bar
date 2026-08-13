import SwiftUI

@main
struct UsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var usageModel = UsageModel()
    @StateObject private var appUpdater = AppUpdater()

    init() {
        AppTheme.loadFont()
    }

    var body: some Scene {
        MenuBarExtra {
            UsageMenuView()
                .environmentObject(usageModel)
                .environmentObject(appUpdater)
        } label: {
            MenuBarLabel(model: usageModel)
                .environmentObject(appUpdater)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(usageModel)
                .environmentObject(appUpdater)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        SMAppServiceLaunchAtLogin.completePendingIfNeeded()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }

    func applicationDidResignActive(_ notification: Notification) {
        let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeKey }
        if !hasVisibleWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: UsageModel
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        Image(nsImage: MenuBarLabelImage.make(segments: model.menuBarSegments))
        .id(model.menuBarSegments.map(\.value).joined(separator: "|"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.menuBarAccessibilityLabel)
        .onAppear {
            model.start()
            updater.startAutomaticChecks()
        }
    }
}
