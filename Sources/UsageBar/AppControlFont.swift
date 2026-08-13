import AppKit
import SwiftUI

enum AppControlFont {
    static func apply(_ font: NSFont, startingAt view: NSView) {
        enclosingButton(from: view)?.font = font
    }

    static func enclosingButton(from view: NSView) -> NSButton? {
        var current: NSView? = view.superview
        while let node = current {
            if let button = node as? NSButton {
                return button
            }
            let buttons = descendantButtons(in: node)
            if buttons.count == 1 {
                return buttons[0]
            }
            current = node.superview
        }
        return nil
    }

    private static func descendantButtons(in view: NSView) -> [NSButton] {
        var buttons: [NSButton] = []
        collectButtons(from: view, into: &buttons)
        return buttons
    }

    private static func collectButtons(from view: NSView, into buttons: inout [NSButton]) {
        if let button = view as? NSButton {
            buttons.append(button)
            return
        }
        for subview in view.subviews {
            collectButtons(from: subview, into: &buttons)
        }
    }
}

private struct AppControlFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content
            .font(AppTheme.font(size: size, weight: weight))
            .background {
                AppControlFontBridge(font: AppTheme.nsFont(size: size, weight: weight))
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct AppControlFontBridge: NSViewRepresentable {
    var font: NSFont?

    func makeNSView(context: Context) -> AppControlFontProbeView {
        AppControlFontProbeView(font: font)
    }

    func updateNSView(_ nsView: AppControlFontProbeView, context: Context) {
        nsView.font = font
        nsView.apply()
    }
}

private final class AppControlFontProbeView: NSView {
    var font: NSFont?

    init(font: NSFont?) {
        self.font = font
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize { .zero }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        apply()
    }

    func apply() {
        guard let font else { return }
        AppControlFont.apply(font, startingAt: self)
        if window != nil, AppControlFont.enclosingButton(from: self) == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, let font = self.font else { return }
                AppControlFont.apply(font, startingAt: self)
            }
        }
    }
}

extension View {
    func appControlFont(size: CGFloat, weight: Font.Weight = .medium) -> some View {
        modifier(AppControlFontModifier(size: size, weight: weight))
    }
}
