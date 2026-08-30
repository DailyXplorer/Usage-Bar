import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let model: UsageModel
    private let updater: AppUpdater
    private let statusItem: NSStatusItem
    private let panel: MenuBarPanel
    private weak var activeButton: NSStatusBarButton?
    private var hostingController: NSHostingController<AnyView>!
    private var modelObservation: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var lastPresentationIdentity: String?
    private var stopped = false

    init(model: UsageModel, updater: AppUpdater) {
        self.model = model
        self.updater = updater
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = MenuBarPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: UsageMenuView.width,
                height: 1
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        let content = UsageMenuView { [weak self] in
            self?.hide()
        }
        .environmentObject(model)
        .environmentObject(updater)
        hostingController = NSHostingController(rootView: AnyView(content))
        hostingController.sizingOptions = [.preferredContentSize]

        configureStatusItem()
        configurePanel()
        observeModel()
        observeScreens()
        updateStatusItem(force: true)
    }

    func stop() {
        guard !stopped else { return }
        hide()
        stopped = true
        modelObservation?.cancel()
        modelObservation = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        panel.contentViewController = nil
        panel.delegate = nil
        panel.onCancel = nil
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePanel(_:))
        button.sendAction(on: [.leftMouseUp])
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = "Usage Bar"
        button.setAccessibilityRole(.menuButton)
        button.setAccessibilityHelp("Open Usage Bar")
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.onCancel = { [weak self] in
            self?.hide()
        }
        panel.setAccessibilityLabel("Usage Bar")
    }

    private func observeModel() {
        modelObservation = model.objectWillChange
            .debounce(for: .milliseconds(10), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.modelDidChange()
            }
    }

    private func observeScreens() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStatusItem(force: true)
                if self?.panel.isVisible == true {
                    self?.hide()
                }
            }
        }
    }

    private func modelDidChange() {
        updateStatusItem()
        guard panel.isVisible else { return }
        DispatchQueue.main.async { [weak self] in
            self?.resizeAndPositionPanel()
        }
    }

    private func updateStatusItem(force: Bool = false) {
        guard let button = statusItem.button else { return }
        let segments = model.menuBarSegments
        let accessibilityLabel = model.menuBarAccessibilityLabel
        let identity = segments.map(\.identity).joined(separator: "|") + "\n" + accessibilityLabel
        guard force || identity != lastPresentationIdentity else { return }
        lastPresentationIdentity = identity
        let scale = button.window?.backingScaleFactor
            ?? button.window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        button.image = MenuBarLabelImage.make(segments: segments, scale: scale)
        button.setAccessibilityLabel(
            accessibilityLabel.isEmpty ? "Usage Bar" : accessibilityLabel
        )
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if panel.isVisible {
            hide()
        } else {
            activeButton = sender
            show()
        }
    }

    private func show() {
        guard !stopped, !panel.isVisible else { return }
        model.refreshNow()
        updater.checkWhenMenuAppears()
        attachPanelContent()
        guard resizeAndPositionPanel() else {
            panel.contentViewController = nil
            activeButton = nil
            return
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        installDismissMonitors()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.statusItem.button?.highlight(true)
        }
    }

    private func hide() {
        removeDismissMonitors()
        statusItem.button?.highlight(false)
        if panel.isVisible {
            panel.orderOut(nil)
        }
        activeButton = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.panel.isVisible else { return }
            self.panel.contentViewController = nil
        }
    }

    private func attachPanelContent() {
        guard panel.contentViewController !== hostingController else { return }
        panel.contentViewController = hostingController
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.cornerRadius = 12
        hostingController.view.layer?.cornerCurve = .continuous
        hostingController.view.layer?.masksToBounds = true
    }

    @discardableResult
    private func resizeAndPositionPanel() -> Bool {
        guard panel.contentViewController === hostingController else { return false }
        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.sizeThatFits(
            in: NSSize(width: UsageMenuView.width, height: 10_000)
        )
        let desiredSize = NSSize(
            width: UsageMenuView.width,
            height: max(1, ceil(fittingSize.height))
        )
        return positionPanel(size: desiredSize)
    }

    @discardableResult
    private func positionPanel(size: NSSize) -> Bool {
        guard let button = activeButton ?? statusItem.button,
              let window = button.window else {
            return false
        }
        let rectInWindow = button.convert(button.bounds, to: nil)
        let anchor = window.convertToScreen(rectInWindow)
        let screens = NSScreen.screens.map {
            MenuBarPanelPlacement.ScreenGeometry(
                frame: $0.frame,
                visibleFrame: $0.visibleFrame
            )
        }
        guard let frame = MenuBarPanelPlacement.frame(
            for: size,
            below: anchor,
            on: screens
        ) else {
            return false
        }
        panel.maxSize = frame.size
        panel.setFrame(frame, display: panel.isVisible)
        return true
    }

    private func installDismissMonitors() {
        if localClickMonitor == nil {
            localClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                let windowNumber = event.windowNumber
                let windowLevel = event.window?.level.rawValue
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let panelWindowNumber = self.panel.windowNumber
                    let buttonWindowNumber = (
                        self.activeButton ?? self.statusItem.button
                    )?.window?.windowNumber
                    let statusBarLevel = NSWindow.Level.statusBar.rawValue
                    if windowNumber != 0,
                       windowNumber != panelWindowNumber,
                       windowNumber != buttonWindowNumber,
                       windowLevel != statusBarLevel {
                        self.hide()
                    }
                }
                return event
            }
        }
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.hide()
                }
            }
        }
        if spaceObserver == nil {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hide()
                }
            }
        }
    }

    private func removeDismissMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
    }
}

extension MenuBarController: NSWindowDelegate {
    nonisolated func windowDidResize(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard (notification.object as? NSWindow) === panel, panel.isVisible else {
                return
            }
            positionPanel(size: panel.frame.size)
        }
    }
}

private final class MenuBarPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
