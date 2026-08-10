import AppKit
import SwiftUI

struct MenuWindowEdgeInset: NSViewRepresentable {
    var margin: CGFloat = 8

    func makeNSView(context: Context) -> NSView {
        EdgeInsetView(margin: margin)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? EdgeInsetView else { return }
        view.margin = margin
        view.applyMargin()
    }
}

private final class EdgeInsetView: NSView {
    var margin: CGFloat
    private var isAdjusting = false
    private var moveObserver: NSObjectProtocol?

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

        guard let window else { return }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.applyMargin()
        }

        applyMargin()
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
