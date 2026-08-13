import AppKit
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
            MenuBarLabel(model: usageModel) {
                appUpdater.startAutomaticChecks()
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(usageModel)
                .environmentObject(appUpdater)
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        SMAppServiceLaunchAtLogin.completePendingIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }

    func applicationDidResignActive(_ notification: Notification) {
        hideDockIconIfNoSettingsWindow()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.hideDockIconIfNoSettingsWindow()
        }
    }

    private func hideDockIconIfNoSettingsWindow() {
        let hasSettingsWindow = NSApp.windows.contains { window in
            window.isVisible
                && !(window is NSPanel)
                && window.canBecomeMain
                && window.styleMask.contains(.titled)
        }
        if !hasSettingsWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: UsageModel
    var startAutomaticChecks: () -> Void = {}

    var body: some View {
        Image(nsImage: MenuBarLabelImage.make(segments: model.menuBarSegments))
        .id(model.menuBarSegments.map(\.value).joined(separator: "|"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.menuBarAccessibilityLabel)
        .onAppear {
            model.start()
            startAutomaticChecks()
        }
    }
}
