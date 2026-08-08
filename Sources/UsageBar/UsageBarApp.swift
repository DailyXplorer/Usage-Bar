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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        Image(nsImage: MenuBarLabelImage.make(
            codex: model.menuBarText,
            claude: model.menuBarClaudeDisplay
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .onAppear { model.start() }
    }

    private var accessibilityLabel: String {
        let codex = "Codex limits, \(model.menuBarAccessibilityText)"
        guard let claude = model.menuBarClaudeAccessibilityText else { return codex }
        return "\(codex). \(claude)"
    }
}
