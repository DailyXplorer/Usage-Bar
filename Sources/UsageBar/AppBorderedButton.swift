import SwiftUI

struct AppBorderedButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppTheme.font(size: 11, weight: .medium))
        }
        .font(AppTheme.font(size: 11, weight: .medium))
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
