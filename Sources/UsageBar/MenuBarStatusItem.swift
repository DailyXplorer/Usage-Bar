import AppKit

@MainActor
enum MenuBarStatusItem {
    static func syncLength(to width: CGFloat) {
        let length = max(width, 1)
        for item in items() {
            applyLength(length, to: item)
        }
    }

    static func applyLength(_ width: CGFloat, to item: NSStatusItem) {
        item.length = max(width, 1)
    }

    static func items() -> [NSStatusItem] {
        var found: [NSStatusItem] = []
        for window in NSApplication.shared.windows where window.className == "NSStatusBarWindow" {
            let raw: Any? = window.value(forKey: "statusItem")
            guard let item = raw as? NSStatusItem else {
                continue
            }
            if !found.contains(where: { $0 === item }) {
                found.append(item)
            }
        }
        return found
    }
}
