import ApplicationServices
import Foundation

enum ApplicationWindowCloseResult: Equatable {
    case requested
    case noClosableWindow
    case permissionDenied
    case failed
}

@MainActor
protocol ApplicationWindowControlling {
    var hasAccessibilityPermission: Bool { get }
    func canCloseWindow(processIdentifiers: [pid_t]) -> Bool
    func closePreferredWindow(processIdentifiers: [pid_t]) -> ApplicationWindowCloseResult
}

struct ApplicationWindowInventory<Window: Equatable> {
    let focusedTopLevelElement: Window?
    let focusedTopLevelElementBlocksFallback: Bool
    let focusedWindow: Window?
    let mainWindow: Window?
    let orderedWindows: [Window]

    init(
        focusedTopLevelElement: Window?,
        focusedTopLevelElementBlocksFallback: Bool = false,
        focusedWindow: Window?,
        mainWindow: Window?,
        orderedWindows: [Window]
    ) {
        self.focusedTopLevelElement = focusedTopLevelElement
        self.focusedTopLevelElementBlocksFallback = focusedTopLevelElementBlocksFallback
        self.focusedWindow = focusedWindow
        self.mainWindow = mainWindow
        self.orderedWindows = orderedWindows
    }
}

enum ApplicationWindowSelection<Window> {
    case window(Window)
    case blocked
    case none
}

enum ApplicationWindowTopLevelClassifier {
    static func blocksFallback(
        role: String?,
        subrole: String? = nil,
        isModal: Bool?
    ) -> Bool {
        if role == kAXSheetRole as String || role == kAXDrawerRole as String {
            return true
        }

        if role == "AXDialog"
            || role == "AXSystemDialog"
            || role == kAXPopoverRole as String
            || role == kAXMenuRole as String {
            return true
        }

        if subrole == kAXDialogSubrole as String
            || subrole == kAXSystemDialogSubrole as String {
            return true
        }

        if isModal == true { return true }

        if role != nil, role != kAXWindowRole as String {
            // A few web and cross-platform apps return their content element
            // from AXTopLevelUIElement. It cannot itself be a modal window, so
            // allow the real AXWindow candidates to be checked below.
            return false
        }

        guard role == kAXWindowRole as String || subrole != nil else {
            return true
        }
        if isModal == false { return false }

        // AXModal is nominally required for windows, but Safari and several
        // Chromium/Electron apps can omit it while inactive. Their standard
        // window subrole is enough to safely fall back to AXFocusedWindow,
        // AXMainWindow, or AXWindows.
        return subrole != kAXStandardWindowSubrole as String
            && subrole != kAXFloatingWindowSubrole as String
            && subrole != kAXSystemFloatingWindowSubrole as String
    }
}

enum ApplicationWindowSelector {
    static func preferredWindow<Window: Equatable>(
        in inventory: ApplicationWindowInventory<Window>,
        isClosable: (Window) -> Bool
    ) -> ApplicationWindowSelection<Window> {
        // A focused sheet or modal surface must block fallback to the document
        // behind it. Closing that document would be surprising and unsafe.
        if let focusedTopLevelElement = inventory.focusedTopLevelElement {
            if isClosable(focusedTopLevelElement) {
                return .window(focusedTopLevelElement)
            }
            if inventory.focusedTopLevelElementBlocksFallback {
                return .blocked
            }
        }

        var candidates: [Window] = []
        appendUnique(inventory.focusedWindow, to: &candidates)
        appendUnique(inventory.mainWindow, to: &candidates)
        inventory.orderedWindows.forEach { appendUnique($0, to: &candidates) }

        if let window = candidates.first(where: isClosable) {
            return .window(window)
        }
        return .none
    }

    private static func appendUnique<Window: Equatable>(
        _ window: Window?,
        to windows: inout [Window]
    ) {
        guard let window, !windows.contains(window) else { return }
        windows.append(window)
    }
}

enum ApplicationWindowPressResult {
    case success
    case cannotComplete
    case failure
}

protocol ApplicationWindowAccessibilityAdapting {
    associatedtype Window: Equatable

    var isTrusted: Bool { get }
    func inventory(for processIdentifier: pid_t) -> ApplicationWindowInventory<Window>?
    func isClosable(_ window: Window) -> Bool
    func pressClose(_ window: Window) -> ApplicationWindowPressResult
}

@MainActor
final class ApplicationWindowService<Adapter: ApplicationWindowAccessibilityAdapting>:
    ApplicationWindowControlling {
    private let adapter: Adapter

    init(adapter: Adapter) {
        self.adapter = adapter
    }

    var hasAccessibilityPermission: Bool {
        adapter.isTrusted
    }

    func canCloseWindow(processIdentifiers: [pid_t]) -> Bool {
        guard adapter.isTrusted else { return false }
        for processIdentifier in processIdentifiers {
            guard let inventory = adapter.inventory(for: processIdentifier) else { continue }
            switch ApplicationWindowSelector.preferredWindow(
                in: inventory,
                isClosable: adapter.isClosable
            ) {
            case .window:
                return true
            case .blocked:
                // A modal surface blocks fallback only within this process;
                // another regular instance may still have a closable window.
                continue
            case .none:
                continue
            }
        }
        return false
    }

    func closePreferredWindow(
        processIdentifiers: [pid_t]
    ) -> ApplicationWindowCloseResult {
        guard adapter.isTrusted else { return .permissionDenied }
        for processIdentifier in processIdentifiers {
            guard let inventory = adapter.inventory(for: processIdentifier) else { continue }
            switch ApplicationWindowSelector.preferredWindow(
                in: inventory,
                isClosable: adapter.isClosable
            ) {
            case let .window(window):
                switch adapter.pressClose(window) {
                case .success, .cannotComplete:
                    // cannotComplete commonly means the target entered a
                    // save-confirmation modal while handling the close press.
                    // Never retry, because that could close a second window.
                    return .requested
                case .failure:
                    return .failed
                }
            case .blocked:
                // Keep the modal-surface safety boundary for this process,
                // while allowing another regular instance to be considered.
                continue
            case .none:
                continue
            }
        }
        return .noClosableWindow
    }
}

struct SystemApplicationWindow: Equatable {
    fileprivate let element: AXUIElement

    static func == (lhs: SystemApplicationWindow, rhs: SystemApplicationWindow) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

struct SystemApplicationWindowAccessibilityAdapter: ApplicationWindowAccessibilityAdapting {
    private static let queryTimeout: Float = 0.4
    private static let actionTimeout: Float = 0.75

    private let permissionService: AccessibilityPermissionService

    init(permissionService: AccessibilityPermissionService = AccessibilityPermissionService()) {
        self.permissionService = permissionService
    }

    var isTrusted: Bool {
        permissionService.isGranted
    }

    func inventory(
        for processIdentifier: pid_t
    ) -> ApplicationWindowInventory<SystemApplicationWindow>? {
        guard isTrusted else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, Self.queryTimeout)

        let focusedUIElement = axElement(application, attribute: kAXFocusedUIElementAttribute)
        if let focusedUIElement {
            _ = AXUIElementSetMessagingTimeout(focusedUIElement, Self.queryTimeout)
        }
        let focusedTopLevelElement = focusedUIElement.flatMap {
            axElement($0, attribute: kAXTopLevelUIElementAttribute)
        }
        if let focusedTopLevelElement {
            _ = AXUIElementSetMessagingTimeout(focusedTopLevelElement, Self.queryTimeout)
        }

        let focusedWindow = axElement(application, attribute: kAXFocusedWindowAttribute)
        let mainWindow = axElement(application, attribute: kAXMainWindowAttribute)
        let orderedWindowsResult = axElements(application, attribute: kAXWindowsAttribute)

        let primaryWindows = [focusedTopLevelElement, focusedWindow, mainWindow]
            .compactMap { $0 }
        if orderedWindowsResult.error != .success,
           orderedWindowsResult.error != .noValue,
           orderedWindowsResult.error != .attributeUnsupported,
           primaryWindows.isEmpty {
            return nil
        }

        let allWindows = primaryWindows + orderedWindowsResult.elements
        allWindows.forEach {
            _ = AXUIElementSetMessagingTimeout($0, Self.queryTimeout)
        }
        return ApplicationWindowInventory(
            focusedTopLevelElement: focusedTopLevelElement.map(SystemApplicationWindow.init),
            focusedTopLevelElementBlocksFallback: focusedTopLevelElement.map {
                isModalTopLevelElement($0)
            } ?? false,
            focusedWindow: focusedWindow.map(SystemApplicationWindow.init),
            mainWindow: mainWindow.map(SystemApplicationWindow.init),
            orderedWindows: orderedWindowsResult.elements.map(SystemApplicationWindow.init)
        )
    }

    func isClosable(_ window: SystemApplicationWindow) -> Bool {
        _ = AXUIElementSetMessagingTimeout(window.element, Self.queryTimeout)
        guard let closeButton = closeButton(for: window.element) else { return false }
        _ = AXUIElementSetMessagingTimeout(closeButton, Self.queryTimeout)
        return axBool(closeButton, attribute: kAXEnabledAttribute) != false
    }

    func pressClose(_ window: SystemApplicationWindow) -> ApplicationWindowPressResult {
        _ = AXUIElementSetMessagingTimeout(window.element, Self.actionTimeout)
        guard let closeButton = closeButton(for: window.element) else { return .failure }
        _ = AXUIElementSetMessagingTimeout(closeButton, Self.actionTimeout)
        if axBool(closeButton, attribute: kAXEnabledAttribute) == false {
            return .failure
        }
        switch AXUIElementPerformAction(closeButton, kAXPressAction as CFString) {
        case .success:
            return .success
        case .cannotComplete:
            return .cannotComplete
        default:
            return .failure
        }
    }

    private func closeButton(for window: AXUIElement) -> AXUIElement? {
        if let closeButton = axElement(window, attribute: kAXCloseButtonAttribute) {
            return closeButton
        }

        // Some third-party accessibility implementations omit the convenience
        // AXCloseButton attribute even though the standard title-bar button is
        // present among the window's direct children.
        return axElements(window, attribute: kAXChildrenAttribute).elements.first { child in
            axString(child, attribute: kAXRoleAttribute) == kAXButtonRole as String
                && axString(child, attribute: kAXSubroleAttribute)
                    == kAXCloseButtonSubrole as String
        }
    }

    private func isModalTopLevelElement(_ element: AXUIElement) -> Bool {
        let role = axString(element, attribute: kAXRoleAttribute)
        let subrole = axString(element, attribute: kAXSubroleAttribute)
        let isModal: Bool?
        if role == kAXWindowRole as String {
            isModal = axBool(element, attribute: kAXModalAttribute)
        } else {
            isModal = nil
        }
        return ApplicationWindowTopLevelClassifier.blocksFallback(
            role: role,
            subrole: subrole,
            isModal: isModal
        )
    }

    private func axElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        let result = axValue(element, attribute: attribute)
        guard result.error == .success,
        let value = result.value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func axElements(
        _ element: AXUIElement,
        attribute: String
    ) -> (elements: [AXUIElement], error: AXError) {
        let result = axValue(element, attribute: attribute)
        guard result.error == .success else { return ([], result.error) }
        return (result.value as? [AXUIElement] ?? [], result.error)
    }

    private func axBool(_ element: AXUIElement, attribute: String) -> Bool? {
        let result = axValue(element, attribute: attribute)
        guard result.error == .success else { return nil }
        return result.value as? Bool
    }

    private func axString(_ element: AXUIElement, attribute: String) -> String? {
        let result = axValue(element, attribute: attribute)
        guard result.error == .success else { return nil }
        return result.value as? String
    }

    private func axValue(
        _ element: AXUIElement,
        attribute: String
    ) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        var error = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        if error == .cannotComplete {
            value = nil
            error = AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &value
            )
        }
        return (value, error)
    }
}

typealias SystemApplicationWindowService = ApplicationWindowService<
    SystemApplicationWindowAccessibilityAdapter
>
