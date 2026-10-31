import AppKit
import ApplicationServices

enum SystemFullScreenWindowSnapshotProvider {
    static func currentSnapshots(
        displays: [FullScreenDisplayGeometry]
    ) -> [FullScreenWindowSnapshot]? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return nil }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        var regularApplications: [pid_t: Bool] = [:]
        var snapshots = windowInfo.compactMap { info -> FullScreenWindowSnapshot? in
            guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
            let pid = pid_t(ownerPID.int32Value)
            guard layer.intValue == 0, pid > 0, pid != currentPID else { return nil }
            let isRegular: Bool
            if let cached = regularApplications[pid] {
                isRegular = cached
            } else {
                isRegular = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
                regularApplications[pid] = isRegular
            }
            let snapshot = FullScreenWindowSnapshot(
                bounds: bounds,
                layer: layer.intValue,
                ownerProcessIdentifier: pid,
                isRegularApplication: isRegular,
                alpha: CGFloat((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1),
                isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
            )
            return FullScreenWindowPolicy.isEligible(snapshot, excludingProcessIdentifier: currentPID)
                ? snapshot : nil
        }

        // This is an optional read of an existing grant, never a permission prompt.
        guard AXIsProcessTrusted() else { return snapshots }
        let candidates = snapshots.indices.filter {
            FullScreenWindowPolicy.needsNativeFullScreenCheck(snapshots[$0], displays: displays)
        }
        let indicesByPID = Dictionary(grouping: candidates) { snapshots[$0].ownerProcessIdentifier }
        for (pid, indices) in indicesByPID {
            let application = AXUIElementCreateApplication(pid)
            _ = AXUIElementSetMessagingTimeout(application, 0.05)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }

            var unmatched = Set(indices)
            for window in windows {
                guard !unmatched.isEmpty else { break }
                guard let state = nativeState(of: window) else { continue }
                let matches = unmatched.filter { boundsMatch(snapshots[$0].bounds, state.bounds) }
                for index in matches {
                    snapshots[index].isNativeFullScreen = state.isFullScreen
                    unmatched.remove(index)
                }
            }
        }
        return snapshots
    }

    private static func nativeState(of window: AXUIElement) -> (bounds: CGRect, isFullScreen: Bool)? {
        _ = AXUIElementSetMessagingTimeout(window, 0.05)
        let attributes = [kAXPositionAttribute, kAXSizeAttribute, "AXFullScreen"] as CFArray
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(window, attributes, [], &result) == .success,
              let values = result as? [Any], values.count == 3,
              let isFullScreen = values[2] as? NSNumber,
              CFGetTypeID(values[0] as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(values[1] as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let positionValue = values[0] as! AXValue
        let sizeValue = values[1] as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return (CGRect(origin: position, size: size), isFullScreen.boolValue)
    }

    private static func boundsMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 3 && abs(lhs.minY - rhs.minY) <= 3
            && abs(lhs.width - rhs.width) <= 3 && abs(lhs.height - rhs.height) <= 3
    }
}
