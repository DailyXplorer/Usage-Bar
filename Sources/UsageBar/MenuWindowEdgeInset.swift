import AppKit
import SwiftUI

struct MenuWindowEdgeInset: NSViewRepresentable {
    var margin: CGFloat = 8
    var onBecomeKey: () -> Void = {}

    func makeNSView(context: Context) -> NSView {
        let view = EdgeInsetView(margin: margin)
        view.onBecomeKey = onBecomeKey
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? EdgeInsetView else { return }
        view.margin = margin
        view.onBecomeKey = onBecomeKey
        view.applyMargin()
    }
}

private final class EdgeInsetView: NSView {
    var margin: CGFloat
    var onBecomeKey: (() -> Void)?
    private var isAdjusting = false
    private var moveObserver: NSObjectProtocol?
    private var keyObserver: NSObjectProtocol?

    init(margin: CGFloat) {
        self.margin = margin
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
            self.moveObserver = nil
        }
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
            self.keyObserver = nil
        }

        guard let window else { return }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.applyMargin()
        }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.onBecomeKey?()
        }

        applyMargin()
        if window.isKeyWindow {
            onBecomeKey?()
        }
    }

    func applyMargin() {
        guard !isAdjusting, let window, let screen = window.screen ?? NSScreen.main else { return }

        let limits = screen.visibleFrame
        let frame = window.frame
        var x = frame.origin.x

        if frame.maxX > limits.maxX - margin {
            x = limits.maxX - margin - frame.width
        }
        x = max(limits.minX + margin, x)

        guard abs(x - frame.origin.x) > 0.5 else { return }

        isAdjusting = true
        window.setFrameOrigin(CGPoint(x: x, y: frame.origin.y))
        isAdjusting = false
    }
}
