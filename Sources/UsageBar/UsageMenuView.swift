import SwiftUI

struct UsageMenuView: View {
    @EnvironmentObject private var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            content

            footer
        }
        .frame(width: 304)
        .background(.regularMaterial)
        .background(MenuWindowEdgeInset())
        .environment(\.font, AppTheme.font(size: 13))
        .onAppear {
            model.refreshNow()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Usage Bar")
                .font(AppTheme.font(size: 15, weight: .semibold))
                .textSelection(.disabled)

            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var hasAnyBucket: Bool {
        (model.isVisibleInMenuBar(.codex) && !model.buckets.isEmpty)
            || (model.isVisibleInMenuBar(.claude) && !model.claudeBuckets.isEmpty)
            || (model.isVisibleInMenuBar(.cursor) && !model.cursorBuckets.isEmpty)
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
            VStack(alignment: .leading, spacing: 14) {
                if model.isVisibleInMenuBar(.codex) {
                    ProviderSection(
                        title: "Codex",
                        plan: model.planType,
                        buckets: model.buckets,
                        message: model.sectionMessage(for: .codex)
                    )
                }

                if model.isVisibleInMenuBar(.claude) {
                    ProviderSection(
                        title: "Claude Code",
                        plan: model.claudePlan,
                        buckets: model.claudeBuckets,
                        message: model.sectionMessage(for: .claude)
                    )
                }

                if model.isVisibleInMenuBar(.cursor) {
                    ProviderSection(
                        title: "Cursor",
                        plan: model.cursorPlan,
                        buckets: model.cursorBuckets,
                        message: model.sectionMessage(for: .cursor)
                    )
                }
            }
            .padding(12)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Group {
                if let updatedAt = model.lastUpdated {
                    Text("Updated at \(updatedAt.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text("Codex, Claude & Cursor usage")
                }
            }
            .font(AppTheme.font(size: 10.5))
            .foregroundStyle(.secondary)
            .monospacedDigit()

            Spacer()

            HStack(spacing: 4) {
                SettingsFooterButton()

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

private struct ProviderSection: View {
    let title: String
    let plan: String?
    let buckets: [LimitBucket]
    let message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(AppTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                if let plan {
                    PlanBadge(plan: plan)
                }
            }
            .padding(.horizontal, 2)

            ForEach(buckets) { bucket in
                LimitCard(bucket: bucket)
            }

            if let message {
                InlineWarning(message: message)
            }
        }
    }
}

private struct PlanBadge: View {
    let plan: String

    private var displayName: String {
        switch plan.lowercased() {
        case "prolite", "pro": return "Pro"
        case "pro_plus", "proplus", "pro+": return "Pro+"
        case "plus": return "Plus"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "ultra": return "Ultra"
        case "max": return "Max"
        default: return plan.capitalized
        }
    }

    var body: some View {
        Text(displayName)
            .font(AppTheme.font(size: 10.5, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct LimitCard: View {
    let bucket: LimitBucket

    private var color: Color {
        if bucket.reached {
            return .red
        }
        return UsageModel.color(forPercentUsed: bucket.usedPercent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bucket.displayName)
                        .font(AppTheme.font(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let detail = bucket.detail {
                        Text(detail)
                            .font(AppTheme.font(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                Text("\(bucket.remainingPercent)%")
                    .font(AppTheme.font(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
            }

            UsageProgressBar(value: bucket.remainingPercent, color: color)

            if bucket.reached {
                Text("Limit reached — no requests left")
                    .font(AppTheme.font(size: 11))
                    .foregroundStyle(.red)
            } else if let resetText = resetText {
                Text(resetText)
                    .font(AppTheme.font(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.primary.opacity(0.08), radius: 0, x: 0, y: 0)
        .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bucket.displayName), \(bucket.remainingPercent) percent left")
    }

    private var resetText: String? {
        let duration = bucket.resetAfterSeconds ?? 0
        guard duration > 0 else { return nil }
        let remaining = UsageModel.durationString(seconds: duration)
        guard let resetAt = bucket.resetAt else {
            return "Resets in \(remaining)"
        }
        let time = resetAt.formatted(date: .omitted, time: .shortened)
        return "Resets in \(remaining) · \(time)"
    }
}

private struct UsageProgressBar: View {
    let value: Int
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))

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
                Text("Connecting to Codex, Claude and Cursor")
                    .font(AppTheme.font(size: 11))
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Retry", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
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
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        FooterIconButton(systemImage: "gearshape", accessibilityLabel: "Settings") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
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
        configuration.label
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.08 : 0),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
