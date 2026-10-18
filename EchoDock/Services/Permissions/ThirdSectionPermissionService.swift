import AppKit

@MainActor
final class ThirdSectionPermissionService {
    private static let noticeVersionKey = "thirdSection.permissionNoticeVersion"
    private static let currentNoticeVersion = 1

    private let defaults: UserDefaults
    private let accessibilityPermissionService: AccessibilityPermissionService

    init(
        defaults: UserDefaults = .standard,
        accessibilityPermissionService: AccessibilityPermissionService = AccessibilityPermissionService()
    ) {
        self.defaults = defaults
        self.accessibilityPermissionService = accessibilityPermissionService
    }

    func presentFirstRunNoticeIfNeeded() {
        guard defaults.integer(forKey: Self.noticeVersionKey) < Self.currentNoticeVersion else {
            return
        }
        defaults.set(Self.currentNoticeVersion, forKey: Self.noticeVersionKey)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text("permissions.thirdSection.title")
        alert.informativeText = L10n.text("permissions.thirdSection.message")
        alert.addButton(withTitle: L10n.text("permissions.thirdSection.authorize"))
        alert.addButton(withTitle: L10n.text("permissions.thirdSection.later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        _ = accessibilityPermissionService.requestIfNeeded()
    }
}
