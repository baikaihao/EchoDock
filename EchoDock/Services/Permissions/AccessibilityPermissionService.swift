import ApplicationServices
import CoreFoundation

struct AccessibilityPermissionButtonState: Equatable {
    let title: String
    let symbolName: String
    let isEnabled: Bool
    let isHidden: Bool

    static func make(isGranted: Bool) -> AccessibilityPermissionButtonState {
        AccessibilityPermissionButtonState(
            title: isGranted
                ? L10n.text("accessibility.granted")
                : L10n.text("accessibility.request"),
            symbolName: isGranted ? "checkmark.shield.fill" : "hand.raised",
            isEnabled: !isGranted,
            isHidden: false
        )
    }
}

struct AccessibilityPermissionService {
    private let trustCheck: () -> Bool
    private let prompt: () -> Bool

    init(
        trustCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        prompt: @escaping () -> Bool = {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        }
    ) {
        self.trustCheck = trustCheck
        self.prompt = prompt
    }

    var isGranted: Bool {
        trustCheck()
    }

    @discardableResult
    func requestIfNeeded() -> Bool {
        guard !trustCheck() else { return true }
        return prompt()
    }
}
