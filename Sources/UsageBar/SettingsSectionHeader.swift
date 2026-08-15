import SwiftUI

struct SettingsSectionHeader: View {
    static let fontSize: CGFloat = 11
    static let fontWeight = Font.Weight.medium
    static let groupedFormInset: CGFloat = 20

    let title: String

    var body: some View {
        Text(title)
            .font(Self.labelFont)
            .appSecondaryLabelStyle()
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    static var labelFont: Font {
        AppTheme.font(size: fontSize, weight: fontWeight)
    }
}
