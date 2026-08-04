import AppKit
import CoreGraphics

struct FullScreenWindowSnapshot: Equatable {
    let bounds: CGRect
    let layer: Int
    let ownerProcessIdentifier: pid_t
    let isRegularApplication: Bool
    let alpha: CGFloat
    let isOnScreen: Bool
}

struct FullScreenDisplayGeometry: Equatable {
    let displayID: CGDirectDisplayID
    let bounds: CGRect
}

enum FullScreenWindowPolicy {
    private static let edgeTolerance: CGFloat = 3
    private static let minimumHorizontalCoverage: CGFloat = 0.98

    static func fullScreenDisplayIDs(
        displays: [FullScreenDisplayGeometry],
        windows: [FullScreenWindowSnapshot],
        excludingProcessIdentifier: pid_t
    ) -> Set<CGDirectDisplayID> {
        let eligibleWindows = windows.filter {
            $0.isOnScreen
                && $0.layer == 0
                && $0.ownerProcessIdentifier > 0
                && $0.ownerProcessIdentifier != excludingProcessIdentifier
                && $0.isRegularApplication
                && $0.alpha > 0.01
                && $0.bounds.width > 0
                && $0.bounds.height > 0
                && !$0.bounds.isInfinite
                && !$0.bounds.isNull
        }

        return Set(displays.compactMap { display in
            guard display.bounds.width > 0, display.bounds.height > 0 else {
                return nil
            }

            let horizontalIntervals = eligibleWindows.compactMap { window -> ClosedRange<CGFloat>? in
                guard spansPhysicalHeight(window.bounds, of: display.bounds) else {
                    return nil
                }
                let intersection = window.bounds.intersection(display.bounds)
                guard !intersection.isNull, intersection.width > 0 else { return nil }
                return intersection.minX...intersection.maxX
            }

            let coveredWidth = mergedLength(of: horizontalIntervals)
            guard coveredWidth / display.bounds.width >= minimumHorizontalCoverage else {
                return nil
            }
            return display.displayID
        })
    }

    private static func spansPhysicalHeight(_ window: CGRect, of display: CGRect) -> Bool {
        window.minY <= display.minY + edgeTolerance
            && window.maxY >= display.maxY - edgeTolerance
    }

    private static func mergedLength(of intervals: [ClosedRange<CGFloat>]) -> CGFloat {
        let sorted = intervals.sorted {
            if $0.lowerBound != $1.lowerBound {
                return $0.lowerBound < $1.lowerBound
            }
            return $0.upperBound < $1.upperBound
        }
        guard var current = sorted.first else { return 0 }

        var total: CGFloat = 0
        for interval in sorted.dropFirst() {
            if interval.lowerBound <= current.upperBound {
                current = current.lowerBound...max(current.upperBound, interval.upperBound)
            } else {
                total += current.upperBound - current.lowerBound
                current = interval
            }
        }
        return total + current.upperBound - current.lowerBound
    }
}

private enum SystemFullScreenWindowSnapshotProvider {
    static func currentSnapshots() -> [FullScreenWindowSnapshot]? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else {
            return nil
        }

        return windowInfo.compactMap { info in
            guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber else {
                return nil
            }
            let processIdentifier = pid_t(ownerPID.int32Value)

            return FullScreenWindowSnapshot(
                bounds: bounds,
                layer: layer.intValue,
                ownerProcessIdentifier: processIdentifier,
                isRegularApplication: NSRunningApplication(
                    processIdentifier: processIdentifier
                )?.activationPolicy == .regular,
                alpha: CGFloat(
                    (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
                ),
                isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
            )
        }
    }
}

@MainActor
final class FullScreenDisplayMonitor {
    typealias WindowSnapshotProvider = () -> [FullScreenWindowSnapshot]?

    private static let transitionSettleDelay: TimeInterval = 0.25

    var onFullScreenDisplaysChange: ((Set<CGDirectDisplayID>) -> Void)?

    private let workspace: NSWorkspace
    private let currentProcessIdentifier: pid_t
    private let windowSnapshotProvider: WindowSnapshotProvider
    private var displayGeometries: [FullScreenDisplayGeometry] = []
    private var fullScreenDisplayIDs: Set<CGDirectDisplayID> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshWorkItem: DispatchWorkItem?
    private var isStarted = false

    init(
        workspace: NSWorkspace = .shared,
        currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        windowSnapshotProvider: @escaping WindowSnapshotProvider = {
            SystemFullScreenWindowSnapshotProvider.currentSnapshots()
        }
    ) {
        self.workspace = workspace
        self.currentProcessIdentifier = currentProcessIdentifier
        self.windowSnapshotProvider = windowSnapshotProvider
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let center = workspace.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRefresh()
                }
            }
        }

        refresh()
    }

    func stop() {
        guard isStarted else { return }
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        let center = workspace.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        displayGeometries.removeAll()
        fullScreenDisplayIDs.removeAll()
        isStarted = false
    }

    func updateDisplays(_ displays: [DisplayDescriptor]) {
        let geometries = displays.compactMap { display -> FullScreenDisplayGeometry? in
            guard !display.isMirrorSecondary else { return nil }
            return FullScreenDisplayGeometry(
                displayID: display.displayID,
                bounds: CGDisplayBounds(display.displayID)
            )
        }
        guard geometries != displayGeometries else { return }
        displayGeometries = geometries
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        refresh()
    }

    private func scheduleRefresh() {
        guard isStarted else { return }
        refreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        refreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.transitionSettleDelay,
            execute: workItem
        )
    }

    private func refresh() {
        guard isStarted, let windows = windowSnapshotProvider() else { return }
        let nextDisplayIDs = FullScreenWindowPolicy.fullScreenDisplayIDs(
            displays: displayGeometries,
            windows: windows,
            excludingProcessIdentifier: currentProcessIdentifier
        )
        guard nextDisplayIDs != fullScreenDisplayIDs else { return }
        fullScreenDisplayIDs = nextDisplayIDs
        onFullScreenDisplaysChange?(nextDisplayIDs)
    }
}
