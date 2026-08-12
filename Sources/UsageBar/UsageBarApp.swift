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
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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

    var body: some View {
        Image(nsImage: MenuBarLabelImage.make(segments: model.menuBarSegments))
        .id(model.menuBarSegments.map(\.value).joined(separator: "|"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.menuBarAccessibilityLabel)
        .onAppear { model.start() }
    }
}
