import AppKit
import Foundation
import UserNotifications

enum NotificationPermission: Equatable {
    case notDetermined, granted, denied
}

@MainActor
protocol UsageNotifying: AnyObject {
    var onOpen: (() -> Void)? { get set }
    func permission() async -> NotificationPermission
    func requestPermission() async -> NotificationPermission
    func post(_ alert: UsageAlert)
}

@MainActor
final class UsageAlertCenter: ObservableObject {
    static let notificationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    @Published var preferences: UsageAlertPreferences {
        didSet {
            guard preferences != oldValue else { return }
            preferences.save(to: defaults)
            let turnedOn = (preferences.warnsWhenLow && !oldValue.warnsWhenLow)
                || (preferences.notifiesOnReset && !oldValue.notifiesOnReset)
            if turnedOn {
                Task { await requestPermissionIfNeeded() }
            }
        }
    }
    @Published private(set) var permission: NotificationPermission
    var openPopover: () -> Void = {}

    private(set) var ledger: UsageAlertLedger
    private let defaults: UserDefaults
    private let notifier: UsageNotifying

    init(
        defaults: UserDefaults = .standard,
        notifier: UsageNotifying? = nil,
        permission: NotificationPermission = .notDetermined
    ) {
        self.defaults = defaults
        let notifier = notifier ?? SystemUsageNotifier.makeForCurrentProcess()
        self.notifier = notifier
        self.permission = permission
        preferences = UsageAlertPreferences.load(from: defaults)
        ledger = UsageAlertLedger.load(from: defaults)
        notifier.onOpen = { [weak self] in
            self?.openPopover()
        }
    }

    @discardableResult
    func receive(provider: LimitBucket.Provider, buckets: [LimitBucket], at date: Date) -> Task<Void, Never>? {
        let result = UsageAlerts.evaluate(
            provider: provider,
            buckets: buckets,
            preferences: preferences,
            ledger: ledger,
            now: date
        )
        if result.ledger != ledger {
            ledger = result.ledger
            ledger.save(to: defaults)
        }
        guard !result.alerts.isEmpty else { return nil }
        return Task { await deliver(result.alerts) }
    }

    func refreshPermission() async {
        permission = await notifier.permission()
    }

    func requestPermissionIfNeeded() async {
        var status = await notifier.permission()
        if status == .notDetermined {
            status = await notifier.requestPermission()
        }
        permission = status
    }

    func openNotificationSettings() {
        NSWorkspace.shared.open(Self.notificationSettingsURL)
    }

    private func deliver(_ alerts: [UsageAlert]) async {
        await requestPermissionIfNeeded()
        guard permission == .granted else { return }
        alerts.forEach(notifier.post)
    }
}

@MainActor
final class SystemUsageNotifier: NSObject, UsageNotifying, UNUserNotificationCenterDelegate {
    var onOpen: (() -> Void)?
    private let center: UNUserNotificationCenter

    private init(center: UNUserNotificationCenter) {
        self.center = center
        super.init()
        center.delegate = self
    }

    static func makeForCurrentProcess() -> UsageNotifying {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app", bundle.bundleIdentifier != nil else {
            return SilentUsageNotifier()
        }
        return SystemUsageNotifier(center: .current())
    }

    func permission() async -> NotificationPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            return .granted
        case .denied:
            return .denied
        default:
            return .notDetermined
        }
    }

    func requestPermission() async -> NotificationPermission {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await permission()
    }

    func post(_ alert: UsageAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "\(alert.key)|\(alert.kind.rawValue)", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            self.onOpen?()
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

@MainActor
final class SilentUsageNotifier: UsageNotifying {
    var onOpen: (() -> Void)?

    func permission() async -> NotificationPermission { .notDetermined }
    func requestPermission() async -> NotificationPermission { .notDetermined }
    func post(_ alert: UsageAlert) {}
}
