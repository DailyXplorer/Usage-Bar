import AppKit
import SwiftUI

struct MenuWindowEdgeInset: NSViewRepresentable {
    var margin: CGFloat = 8
    var onShown: () -> Void = {}

    func makeNSView(context: Context) -> NSView {
        let view = EdgeInsetView(margin: margin)
        view.onShown = onShown
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? EdgeInsetView else { return }
        view.margin = margin
        view.onShown = onShown
        view.applyMargin()
    }
}

private final class EdgeInsetView: NSView {
    var margin: CGFloat
    var onShown: (() -> Void)?
    private var isAdjusting = false
    private var moveObserver: NSObjectProtocol?
    private var visibilityObservation: NSKeyValueObservation?

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
        visibilityObservation?.invalidate()
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
        visibilityObservation?.invalidate()
        visibilityObservation = nil

        guard let window else { return }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.applyMargin()
        }
        visibilityObservation = window.observe(\.isVisible, options: [.new]) { [weak self] window, _ in
            guard window.isVisible else { return }
            self?.onShown?()
        }

        applyMargin()
        if window.isVisible {
            onShown?()
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
