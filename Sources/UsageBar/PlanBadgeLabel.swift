import Foundation

enum PlanBadgeLabel {
    static func text(for plan: String, provider: LimitBucket.Provider) -> String {
        let key = normalized(plan)
        switch provider {
        case .codex:
            return codexText(for: key, original: plan)
        case .claude:
            return claudeText(for: key, original: plan)
        case .cursor:
            return sharedText(for: key, original: plan)
        case .opencode:
            return opencodeText(for: key, original: plan)
        }
    }

    private static func codexText(for key: String, original: String) -> String {
        switch key {
        case "prolite":
            return "Pro 5x"
        case "pro":
            return "Pro 20x"
        default:
            return sharedText(for: key, original: original)
        }
    }

    private static func claudeText(for key: String, original: String) -> String {
        switch key {
        case "max5x":
            return "Max 5x"
        case "max20x":
            return "Max 20x"
        default:
            return sharedText(for: key, original: original)
        }
    }

    private static func opencodeText(for key: String, original: String) -> String {
        if key == normalized(OpenCodeLimits.planName) {
            return OpenCodeLimits.planName
        }
        return sharedText(for: key, original: original)
    }

    private static func sharedText(for key: String, original: String) -> String {
        switch key {
        case "prolite", "pro":
            return "Pro"
        case "proplus", "pro+":
            return "Pro+"
        case "plus":
            return "Plus"
        case "team":
            return "Team"
        case "business":
            return "Business"
        case "enterprise":
            return "Enterprise"
        case "ultra":
            return "Ultra"
        case "max":
            return "Max"
        default:
            return original.capitalized
        }
    }

    private static func normalized(_ plan: String) -> String {
        plan.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }
}
