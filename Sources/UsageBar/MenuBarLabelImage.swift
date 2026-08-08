import AppKit
import SwiftUI

@MainActor
enum MenuBarLabelImage {
    static let iconSize: CGFloat = 12
    static let fontSize: CGFloat = 12

    static func make(codex: String, claude: String) -> NSImage {
        let content = HStack(spacing: 0) {
            logo(AppTheme.codexLogo)
            value(codex)
                .padding(.leading, 4)
            logo(AppTheme.claudeLogo)
                .padding(.leading, 7)
            value(claude)
                .padding(.leading, 4)
        }
        .foregroundStyle(.black)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        image.isTemplate = true
        return image
    }

    @ViewBuilder
    private static func logo(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
        }
    }

    private static func value(_ text: String) -> some View {
        Text(text)
            .font(AppTheme.font(size: fontSize, weight: .semibold))
            .monospacedDigit()
    }
}
