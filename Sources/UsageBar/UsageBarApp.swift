import AppKit
import SwiftUI

@main
struct UsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppTheme.loadFont()
    }

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.usageModel)
                .environmentObject(appDelegate.appUpdater)
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let usageModel = UsageModel()
    let appUpdater = AppUpdater()

    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBarController = MenuBarController(model: usageModel, updater: appUpdater)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        usageModel.start()
        appUpdater.startAutomaticChecks()
        DispatchQueue.global(qos: .utility).async {
            let completed = SMAppServiceLaunchAtLogin.pendingEnableCompleted()
            guard completed else { return }
            DispatchQueue.main.async {
                UserDefaults.standard.set(false, forKey: AppInstallLocation.pendingKey)
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageModel.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        menuBarController?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }

    func applicationDidResignActive(_ notification: Notification) {
        hideDockIconIfNoSettingsWindow()
    }

    @objc private func workspaceWillSleep(_ notification: Notification) {
        usageModel.setSleeping(true)
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        usageModel.setSleeping(false)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.hideDockIconIfNoSettingsWindow()
        }
    }

    private func hideDockIconIfNoSettingsWindow() {
        let hasSettingsWindow = NSApp.windows.contains { window in
            window.isVisible && SettingsWindowPresenter.isSettingsWindow(window)
        }
        if !hasSettingsWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
