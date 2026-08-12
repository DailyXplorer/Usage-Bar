import AppKit
import SwiftUI

struct MenuBarSegment {
    let logo: NSImage?
    let value: String
}

@MainActor
enum MenuBarLabelImage {
    static let iconSize: CGFloat = 12
    static let fontSize: CGFloat = 12

    static func make(segments: [MenuBarSegment]) -> NSImage {
        let content = HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                HStack(spacing: 4) {
                    logo(segment.logo)
                    value(segment.value)
                }
                .padding(.leading, index == 0 ? 0 : 7)
            }
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

    static func make(codex: String, claude: String) -> NSImage {
        make(segments: [
            MenuBarSegment(logo: AppTheme.codexLogo, value: codex),
            MenuBarSegment(logo: AppTheme.claudeLogo, value: claude),
        ])
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
