import SwiftUI

struct AppBorderedButton: View {
    static let fontSize: CGFloat = 11
    static let fontWeight = Font.Weight.medium

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Self.labelFont)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    static var labelFont: Font {
        AppTheme.font(size: fontSize, weight: fontWeight)
    }
}
