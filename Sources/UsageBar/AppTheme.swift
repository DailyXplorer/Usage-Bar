import SwiftUI

enum AppTheme {
    private static let baseFontName = "InstrumentSans-Regular"
    private static let weightAxisIdentifier = 2_003_265_652

    static var resourceBundle: Bundle {
        if let bundledURL = Bundle.main.url(
            forResource: "UsageBar_UsageBar",
            withExtension: "bundle"
        ), let bundledResources = Bundle(url: bundledURL) {
            return bundledResources
        }
        return Bundle.module
    }

    static func loadFont() {
        let bundle = resourceBundle
        guard let url = bundle.url(forResource: "InstrumentSans", withExtension: "ttf") else {
            return
        }
        var error: Unmanaged<CFError>?
        guard let provider = CGDataProvider(url: url as CFURL) else { return }
        guard let font = CGFont(provider) else { return }
        if !CTFontManagerRegisterGraphicsFont(font, &error) {
            return
        }
    }

    static let codexLogo: NSImage? = logo(named: "chat-gpt")
    static let claudeLogo: NSImage? = logo(named: "claude")
    static let cursorLogo: NSImage? = logo(named: "cursor")

    static func logo(for provider: LimitBucket.Provider) -> NSImage? {
        switch provider {
        case .codex: return codexLogo
        case .claude: return claudeLogo
        case .cursor: return cursorLogo
        }
    }

    private static func logo(named name: String) -> NSImage? {
        guard let url = resourceBundle.url(forResource: name, withExtension: "svg"),
              let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard let nsFont = nsFont(size: size, weight: weight) else {
            return Font.system(size: size, weight: weight)
        }
        return Font(nsFont)
    }

    static func nsFont(size: CGFloat, weight: Font.Weight = .regular) -> NSFont? {
        guard let base = NSFont(name: baseFontName, size: size) else { return nil }
        let axisValue = weightAxisValue(for: weight)
        guard axisValue != 400 else { return base }
        let descriptor = base.fontDescriptor.addingAttributes([
            NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String): [
                weightAxisIdentifier: axisValue
            ]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private static func weightAxisValue(for weight: Font.Weight) -> Int {
        switch weight {
        case .medium:
            return 500
        case .semibold:
            return 600
        case .bold, .heavy, .black:
            return 700
        default:
            return 400
        }
    }
}

extension Color {
    var hexString: String {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((nsColor.redComponent * 255).rounded())
        let g = Int((nsColor.greenComponent * 255).rounded())
        let b = Int((nsColor.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
