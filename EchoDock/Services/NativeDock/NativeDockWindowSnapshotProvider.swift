import AppKit
import ApplicationServices

struct NativeDockWindowSnapshot {
    let dockLists: [NativeDockWindowGeometry]
    let windows: [NativeDockWindowGeometry]

    func displayID(displays: [NativeDockLockDisplayGeometry], edge: NativeDockLockEdge) -> CGDirectDisplayID? {
        NativeDockDisplayDetector.displayID(for: dockLists, displays: displays, edge: edge)
            ?? NativeDockDisplayDetector.displayID(for: windows, displays: displays, edge: edge)
    }
}

struct NativeDockWindowSnapshotProvider {
    let budget: AccessibilityOperationBudget

    func snapshots() -> NativeDockWindowSnapshot? {
        guard AXIsProcessTrusted(), budget.canContinue,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, 0.05)
        let lists = dockListGeometries(in: application)
        guard budget.canContinue else { return nil }
        let windows = axElements(application, attribute: kAXWindowsAttribute).compactMap(axGeometry)
        return budget.canContinue ? NativeDockWindowSnapshot(dockLists: lists, windows: windows) : nil
    }

    private func dockListGeometries(in application: AXUIElement) -> [NativeDockWindowGeometry] {
        var queue = axElements(
            application,
            attribute: kAXChildrenAttribute
        ).map { (element: $0, depth: 1) }
        var nextIndex = 0
        var inspectedCount = 0
        var result: [NativeDockWindowGeometry] = []

        while nextIndex < queue.count, inspectedCount < 128, budget.canContinue {
            let entry = queue[nextIndex]
            nextIndex += 1
            inspectedCount += 1

            let role = axString(entry.element, attribute: kAXRoleAttribute)
            let subrole = axString(entry.element, attribute: kAXSubroleAttribute)
            let children = axElements(entry.element, attribute: kAXChildrenAttribute)
            let containsDockItem = children.prefix(32).contains { child in
                let childRole = axString(child, attribute: kAXRoleAttribute)
                let childSubrole = axString(child, attribute: kAXSubroleAttribute)
                return childRole == "AXDockItem"
                    || childSubrole == "AXDockItem"
                    || childSubrole?.contains("DockItem") == true
            }
            let isDockList = subrole == "AXDockList"
                || (role == "AXList" && containsDockItem)

            if isDockList, let geometry = axGeometry(entry.element) {
                result.append(geometry)
                continue
            }

            if entry.depth < 5 {
                queue.append(contentsOf: children.prefix(64).map {
                    (element: $0, depth: entry.depth + 1)
                })
            }
        }

        return result
    }

    private func axGeometry(_ element: AXUIElement) -> NativeDockWindowGeometry? {
        guard let position = axPoint(element, attribute: kAXPositionAttribute),
              let size = axSize(element, attribute: kAXSizeAttribute) else {
            return nil
        }
        return NativeDockWindowGeometry(
            frame: CGRect(origin: position, size: size)
        )
    }

    private func axElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        guard budget.canContinue else { return [] }
        _ = AXUIElementSetMessagingTimeout(element, Float(min(0.05, max(0.001, budget.remaining))))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private func axString(_ element: AXUIElement, attribute: String) -> String? {
        guard budget.canContinue else { return nil }
        _ = AXUIElementSetMessagingTimeout(element, Float(min(0.05, max(0.001, budget.remaining))))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func axPoint(_ element: AXUIElement, attribute: String) -> CGPoint? {
        guard budget.canContinue else { return nil }
        _ = AXUIElementSetMessagingTimeout(element, Float(min(0.05, max(0.001, budget.remaining))))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private func axSize(_ element: AXUIElement, attribute: String) -> CGSize? {
        guard budget.canContinue else { return nil }
        _ = AXUIElementSetMessagingTimeout(element, Float(min(0.05, max(0.001, budget.remaining))))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }
}
