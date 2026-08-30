import CoreGraphics

enum MenuBarPanelPlacement {
    struct ScreenGeometry {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    private static let buttonGap: CGFloat = 2

    static func frame(
        for panelSize: CGSize,
        below statusButtonFrame: CGRect,
        on screens: [ScreenGeometry],
        margin: CGFloat = 8
    ) -> CGRect? {
        let buttonFrame = statusButtonFrame.standardized
        guard let screen = matchingScreen(for: buttonFrame, in: screens) else {
            return nil
        }

        let visibleFrame = screen.visibleFrame.standardized
        let safeMargin = max(0, margin)
        let horizontalMargin = min(safeMargin, visibleFrame.width / 2)
        let bottomMargin = min(safeMargin, visibleFrame.height)
        let placementFrame = CGRect(
            x: visibleFrame.minX + horizontalMargin,
            y: visibleFrame.minY + bottomMargin,
            width: max(0, visibleFrame.width - horizontalMargin * 2),
            height: max(0, visibleFrame.height - bottomMargin)
        )

        let panelWidth = min(max(0, panelSize.width), placementFrame.width)
        let centeredX = buttonFrame.midX - panelWidth / 2
        let panelX = min(
            max(centeredX, placementFrame.minX),
            placementFrame.maxX - panelWidth
        )

        let desiredTop = buttonFrame.minY - buttonGap
        let panelTop = min(
            max(desiredTop, placementFrame.minY),
            placementFrame.maxY
        )
        let availableHeight = max(0, panelTop - placementFrame.minY)
        let panelHeight = min(max(0, panelSize.height), availableHeight)

        return CGRect(
            x: panelX,
            y: panelTop - panelHeight,
            width: panelWidth,
            height: panelHeight
        )
    }

    private static func matchingScreen(
        for buttonFrame: CGRect,
        in screens: [ScreenGeometry]
    ) -> ScreenGeometry? {
        if let containingScreen = screens.first(where: {
            $0.frame.standardized.contains(buttonFrame)
        }) {
            return containingScreen
        }

        var matchingScreen: ScreenGeometry?
        var largestIntersectionArea: CGFloat = 0

        for screen in screens {
            let intersection = screen.frame.standardized.intersection(buttonFrame)
            guard !intersection.isNull, !intersection.isEmpty else {
                continue
            }

            let intersectionArea = intersection.width * intersection.height
            if intersectionArea > largestIntersectionArea {
                matchingScreen = screen
                largestIntersectionArea = intersectionArea
            }
        }

        return matchingScreen
    }
}
