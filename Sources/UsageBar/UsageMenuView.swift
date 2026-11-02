import AppKit
import SwiftUI

struct UsageMenuView: View {
    static let width: CGFloat = 304

    var onBeforeOpenSettings: () -> Void = {}
    var contentMaxHeight: CGFloat = 434

    @State private var displayDate = Date()

    @EnvironmentObject private var model: UsageModel
    @EnvironmentObject private var updater: AppUpdater
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            content

            footer
        }
        .frame(width: Self.width)
        .background(
            AppTheme.menuBackground(
                colorScheme: colorScheme,
                contrast: colorSchemeContrast
            )
        )
        .environment(\.font, AppTheme.font(size: 13))
        .task(id: model.menuPresented) {
            displayDate = Date()
            guard model.menuPresented else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    return
                }
                displayDate = Date()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Usage Bar")
                .font(AppTheme.font(size: 15, weight: .semibold))
                .textSelection(.disabled)

            Spacer()

            FooterIconButton(systemImage: "arrow.clockwise", accessibilityLabel: "Refresh usage") {
                model.refreshNow(force: true)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(
            AppTheme.inkOverlay(
                colorScheme: colorScheme,
                contrast: colorSchemeContrast,
                standardOpacity: 0.025
            )
        )
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var hasAnyBucket: Bool {
        LimitBucket.Provider.allCases.contains {
            model.isVisibleInPopover($0) && !model.buckets(for: $0).isEmpty
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && !hasAnyBucket {
            LoadingView()
        } else if !hasAnyBucket {
            ErrorView(message: model.visibleEmptyStateMessage) {
                model.refreshNow(force: true)
            }
        } else {
            ViewThatFits(in: .vertical) {
                providerContent
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView(.vertical) {
                    providerContent
                }
                .scrollIndicators(.visible)
            }
            .frame(maxHeight: contentMaxHeight)
        }
    }

    private var providerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(LimitBucket.Provider.allCases.filter(model.isVisibleInPopover)) { provider in
                ProviderSection(
                    provider: provider,
                    plan: model.plan(for: provider),
                    buckets: model.buckets(for: provider),
                    message: model.popoverMessage(for: provider),
                    freshness: model.freshnessMessage(for: provider, at: displayDate),
                    date: displayDate,
                    fetchedAt: model.dataDate(for: provider),
                    supplementalMessage: provider == .cursor && !model.cursorBuckets.isEmpty ? model.cursorNotice : nil
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.updatedText(at: displayDate))
            .font(AppTheme.font(size: 10.5))
            .appSecondaryLabelStyle()
            .monospacedDigit()

            Spacer()

            HStack(spacing: 4) {
                if updater.state.showsUpdateAction {
                    FooterIconButton(
                        systemImage: "arrow.down.app",
                        accessibilityLabel: updater.buttonTitle
                    ) {
                        updater.performButtonAction()
                    }
                    .disabled(updater.isBusy)
                }

                SettingsFooterButton(onBeforeOpen: onBeforeOpenSettings)

                FooterIconButton(systemImage: "power", accessibilityLabel: "Quit") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct ProviderMark: View {
    let provider: LimitBucket.Provider

    var body: some View {
        Group {
            if let image = AppTheme.logo(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .offset(y: 2)
            } else {
                Text(provider.title)
                    .font(AppTheme.font(size: 11, weight: .medium))
            }
        }
        .appSecondaryLabelStyle()
        .accessibilityLabel(provider.title)
    }
}

private struct ProviderSection: View {
    let provider: LimitBucket.Provider
    let plan: String?
    let buckets: [LimitBucket]
    let message: String?
    let freshness: String?
    let date: Date
    let fetchedAt: Date?
    var supplementalMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProviderMark(provider: provider)

                Spacer()

                if let plan {
                    PlanBadge(plan: plan, provider: provider)
                }
            }
            .padding(.horizontal, 2)

            ForEach(buckets) { bucket in
                if bucket.isValueOnly {
                    ValueRow(bucket: bucket)
                } else {
                    LimitCard(bucket: bucket, date: date, fetchedAt: fetchedAt)
                }
            }

            if let message {
                InlineWarning(message: message)
            }
            if let supplementalMessage {
                InlineWarning(message: supplementalMessage)
            }
            if !buckets.isEmpty, let freshness {
                Text(freshness)
                    .font(AppTheme.font(size: 10))
                    .appSecondaryLabelStyle()
                    .monospacedDigit()
            }
        }
    }
}

private struct PlanBadge: View {
    let plan: String
    let provider: LimitBucket.Provider

    private var displayName: String {
        PlanBadgeLabel.text(for: plan, provider: provider)
    }

    var body: some View {
        Text(displayName)
            .font(AppTheme.font(size: 10.5, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .appSecondaryLabelStyle()
            .lineLimit(1)
    }
}

private struct ValueRow: View {
    let bucket: LimitBucket

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(bucket.displayName)
                .font(AppTheme.font(size: 12, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 8)

            if let detail = bucket.detail {
                Text(detail)
                    .font(AppTheme.font(size: 11, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([bucket.displayName, bucket.detail].compactMap { $0 }.joined(separator: ", "))
    }
}

private struct LimitCard: View {
    let bucket: LimitBucket
    let date: Date
    let fetchedAt: Date?

    private var hasReset: Bool {
        bucket.hasReset(at: date, since: fetchedAt)
    }

    private var shown: LimitBucket {
        bucket.resetApplied(at: date, since: fetchedAt)
    }

    private var color: Color {
        if shown.reached {
            return .red
        }
        return UsageModel.color(forPercentUsed: shown.usedPercent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bucket.displayName)
                    .font(AppTheme.font(size: 12, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                trailingCaption
            }

            UsageProgressBar(value: shown.remainingPercent, color: color)

            Text("\(shown.remainingPercent)% Left")
                .font(AppTheme.font(size: 11, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())

            if let detail = bucket.detail {
                Text(detail)
                    .font(AppTheme.font(size: 10.5))
                    .appSecondaryLabelStyle()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var trailingCaption: some View {
        if hasReset {
            Text(Self.resetCaption)
                .font(AppTheme.font(size: 10.5))
                .appSecondaryLabelStyle()
                .lineLimit(1)
        } else if bucket.reached {
            Text("Limit reached")
                .font(AppTheme.font(size: 10.5))
                .foregroundStyle(.red)
                .lineLimit(1)
        } else if let resetText {
            Text(resetText)
                .font(AppTheme.font(size: 10.5))
                .appSecondaryLabelStyle()
                .lineLimit(1)
        }
    }

    static let resetCaption = "Reset, waiting for new data"

    private var resetText: String? {
        let duration = bucket.remainingResetSeconds(at: date) ?? 0
        guard duration > 0 else { return nil }
        return "Resets in \(UsageModel.durationString(seconds: duration))"
    }

    private var accessibilityText: String {
        var parts = ["\(bucket.displayName), \(shown.remainingPercent) percent left"]
        if hasReset {
            parts.append(Self.resetCaption)
        } else if bucket.reached {
            parts.append("limit reached")
        } else if let resetText {
            parts.append(resetText)
        }
        return parts.joined(separator: ", ")
    }
}

private struct UsageProgressBar: View {
    let value: Int
    let color: Color
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(
                        AppTheme.inkOverlay(
                            colorScheme: colorScheme,
                            contrast: colorSchemeContrast,
                            standardOpacity: 0.08
                        )
                    )

                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * CGFloat(max(0, min(100, value))) / 100)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.25), value: value)
        .accessibilityHidden(true)
    }
}

private struct LoadingView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text("Loading limits…")
                    .font(AppTheme.font(size: 13, weight: .medium))
                Text("Connecting to your enabled plans")
                    .font(AppTheme.font(size: 11))
                    .appSecondaryLabelStyle()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

private struct ErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Couldn’t load limits", systemImage: "exclamationmark.triangle.fill")
                .font(AppTheme.font(size: 13, weight: .semibold))
                .foregroundStyle(.orange)

            Text(message)
                .font(AppTheme.font(size: 11.5))
                .appSecondaryLabelStyle()
                .fixedSize(horizontal: false, vertical: true)

            AppBorderedButton(title: "Retry", action: retry)
        }
        .padding(16)
    }
}

private struct InlineWarning: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(AppTheme.font(size: 10.5))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }
}

private struct SettingsFooterButton: View {
    let onBeforeOpen: () -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        FooterIconButton(systemImage: "gearshape", accessibilityLabel: "Settings") {
            onBeforeOpen()
            SettingsWindowPresenter.present {
                openSettings()
            }
        }
    }
}

private struct FooterIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.monochrome)
        }
        .buttonStyle(FooterButtonStyle())
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FooterButtonBody(configuration: configuration)
    }
}

private struct FooterButtonBody: View {
    let configuration: ButtonStyle.Configuration

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        configuration.label
            .appSecondaryLabelStyle()
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        AppTheme.inkOverlay(
                            colorScheme: colorScheme,
                            contrast: colorSchemeContrast,
                            standardOpacity: configuration.isPressed ? 0.08 : 0
                        )
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
