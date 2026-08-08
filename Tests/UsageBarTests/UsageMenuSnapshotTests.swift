import AppKit
import SwiftUI
import XCTest
@testable import UsageBar

final class UsageMenuSnapshotTests: XCTestCase {
    @MainActor
    func testMenuRendersInLightAndDarkModes() throws {
        AppTheme.loadFont()
        let model = UsageModel(
            previewBuckets: [
                LimitBucket(
                    kind: .primary,
                    name: "weekly",
                    usedPercent: 42,
                    resetAt: Date(timeIntervalSince1970: 1_786_189_759),
                    resetAfterSeconds: 231_321,
                    limitWindowSeconds: 604_800,
                    reached: false
                )
            ],
            planType: "prolite",
            lastUpdated: Date(),
            claudeBuckets: [
                LimitBucket(
                    provider: .claude,
                    kind: .session,
                    name: "Session 5h",
                    usedPercent: 12,
                    resetAt: Date(timeIntervalSince1970: 1_786_232_400),
                    resetAfterSeconds: 7_200,
                    limitWindowSeconds: 18_000,
                    reached: false
                ),
                LimitBucket(
                    provider: .claude,
                    kind: .weeklyAll,
                    name: "Week · All models",
                    usedPercent: 40,
                    resetAt: Date(timeIntervalSince1970: 1_786_402_800),
                    resetAfterSeconds: 177_600,
                    limitWindowSeconds: 604_800,
                    reached: false
                ),
                LimitBucket(
                    provider: .claude,
                    kind: .weeklyScoped,
                    name: "Week · Opus",
                    usedPercent: 91,
                    resetAt: Date(timeIntervalSince1970: 1_786_402_800),
                    resetAfterSeconds: 177_600,
                    limitWindowSeconds: 604_800,
                    reached: false
                ),
            ],
            claudePlan: "max"
        )

        let buildDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)

        try render(
            UsageMenuView()
                .environmentObject(model)
                .environment(\.colorScheme, .light),
            to: buildDirectory.appendingPathComponent("UsageBar-light.png")
        )
        try render(
            UsageMenuView()
                .environmentObject(model)
                .environment(\.colorScheme, .dark),
            to: buildDirectory.appendingPathComponent("UsageBar-dark.png")
        )
    }

    @MainActor
    private func render<Content: View>(_ content: Content, to url: URL) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.nsImage)
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try pngData.write(to: url, options: .atomic)
    }
}
