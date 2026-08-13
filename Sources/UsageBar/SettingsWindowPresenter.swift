import AppKit
import SwiftUI

struct SettingsWindowTraits: Equatable {
    var identifier: NSUserInterfaceItemIdentifier?
    var isPanel: Bool
    var canBecomeMain: Bool
    var isTitled: Bool
}

@MainActor
enum SettingsWindowPresenter {
    static let swiftUISettingsIdentifier = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")

    static func present(using openSettings: @escaping () -> Void) {
        if let window = settingsWindow() {
            revealOnActiveSpace(window)
            return
        }

        openSettings()
        adoptVisibleSettingsWindow()
        DispatchQueue.main.async {
            adoptVisibleSettingsWindow()
            DispatchQueue.main.async {
                adoptVisibleSettingsWindow()
            }
        }
    }

    static func adoptVisibleSettingsWindow() {
        guard let window = settingsWindow() else { return }
        revealOnActiveSpace(window)
    }

    static func isSettingsWindow(_ window: NSWindow) -> Bool {
        isSettingsWindow(
            SettingsWindowTraits(
                identifier: window.identifier,
                isPanel: window is NSPanel,
                canBecomeMain: window.canBecomeMain,
                isTitled: window.styleMask.contains(.titled)
            )
        )
    }

    static func isSettingsWindow(_ traits: SettingsWindowTraits) -> Bool {
        if traits.identifier == swiftUISettingsIdentifier {
            return true
        }
        guard !traits.isPanel else { return false }
        return traits.canBecomeMain && traits.isTitled
    }

    static func collectionBehaviorForActiveSpace(
        _ current: NSWindow.CollectionBehavior
    ) -> NSWindow.CollectionBehavior {
        current
            .subtracting([.canJoinAllSpaces, .fullScreenNone, .fullScreenPrimary])
            .union([.moveToActiveSpace, .fullScreenAuxiliary])
    }

    static func settingsWindow() -> NSWindow? {
        NSApp.windows.first(where: isSettingsWindow)
    }

    static func revealOnActiveSpace(_ window: NSWindow) {
        guard !isRevealing else { return }
        isRevealing = true
        defer { isRevealing = false }

        window.collectionBehavior = collectionBehaviorForActiveSpace(window.collectionBehavior)
        window.orderFrontRegardless()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private static var isRevealing = false
}

struct SettingsWindowSpacePin: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SpacePinView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SpacePinView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        SettingsWindowPresenter.revealOnActiveSpace(window)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
