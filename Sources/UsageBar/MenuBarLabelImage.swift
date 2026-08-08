import AppKit
import SwiftUI

/// `MenuBarExtra` ne rend qu'une image et un texte dans son label : impossible d'y
/// poser deux logos côte à côte, et une image interpolée dans un `Text` est
/// supprimée. On compose donc le libellé entier — logo, valeur, logo, valeur —
/// hors écran, et on ne remet qu'une seule `Image` template à la barre.
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
        // Template : la barre de menus le teinte elle-même selon le thème.
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
