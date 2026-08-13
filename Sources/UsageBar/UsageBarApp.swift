import AppKit
import SwiftUI

@main
struct UsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var usageModel = UsageModel()

    init() {
        AppTheme.loadFont()
    }

    var body: some Scene {
        MenuBarExtra {
            UsageMenuView()
                .environmentObject(usageModel)
        } label: {
            MenuBarLabel(model: usageModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(usageModel)
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
            window.isVisible && SettingsWindowPresenter.isSettingsWindow(window)
        }
        if !hasSettingsWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        Image(nsImage: MenuBarLabelImage.make(segments: model.menuBarSegments))
        .id(model.menuBarSegments.map(\.value).joined(separator: "|"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.menuBarAccessibilityLabel)
        .onAppear { model.start() }
    }
}
