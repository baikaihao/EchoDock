import AppKit
import CoreGraphics

struct FullScreenWindowSnapshot: Equatable, Sendable {
    let bounds: CGRect
    let layer: Int
    let ownerProcessIdentifier: pid_t
    let isRegularApplication: Bool
    let alpha: CGFloat
    let isOnScreen: Bool
    var isNativeFullScreen: Bool? = nil
}

struct FullScreenDisplayGeometry: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let bounds: CGRect
    var topSafeAreaInset: CGFloat = 0
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
            isEligible($0, excludingProcessIdentifier: excludingProcessIdentifier)
        }
        let validDisplays = displays.filter { isValid($0.bounds) }
        // AXFullScreen identifies native full screen even when macOS leaves
        // space for the menu bar or Chrome hosts its toolbar in another window.
        // Only on-screen CG windows participate, so another Space cannot hide us.
        let nativeDisplayIDs = Set(eligibleWindows.compactMap { window -> CGDirectDisplayID? in
            guard window.isNativeFullScreen == true else { return nil }
            return validDisplays.max {
                intersectionArea(window.bounds, $0.bounds) < intersectionArea(window.bounds, $1.bounds)
            }.flatMap { display in
                intersectionArea(window.bounds, display.bounds) > 0 ? display.displayID : nil
            }
        })

        return Set(validDisplays.compactMap { display in
            if nativeDisplayIDs.contains(display.displayID) { return display.displayID }

            let horizontalIntervals = eligibleWindows.compactMap { window -> ClosedRange<CGFloat>? in
                guard spansFullScreenHeight(window, of: display) else {
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

    static func isEligible(
        _ window: FullScreenWindowSnapshot,
        excludingProcessIdentifier: pid_t
    ) -> Bool {
        window.isOnScreen
            && window.layer == 0
            && window.ownerProcessIdentifier > 0
            && window.ownerProcessIdentifier != excludingProcessIdentifier
            && window.isRegularApplication
            && window.alpha > 0.01
            && isValid(window.bounds)
    }

    static func needsNativeFullScreenCheck(
        _ window: FullScreenWindowSnapshot,
        displays: [FullScreenDisplayGeometry]
    ) -> Bool {
        // Full-height borderless windows already have a conclusive geometry
        // result. Limit AX IPC to large windows with an ambiguous top edge.
        displays.contains { display in
            isValid(display.bounds)
                && !spansPhysicalHeight(window.bounds, of: display.bounds)
                && intersectionArea(window.bounds, display.bounds)
                    >= display.bounds.width * display.bounds.height * 0.35
                && window.bounds.height >= display.bounds.height * 0.7
        }
    }

    private static func spansFullScreenHeight(
        _ window: FullScreenWindowSnapshot,
        of display: FullScreenDisplayGeometry
    ) -> Bool {
        if spansPhysicalHeight(window.bounds, of: display.bounds) { return true }
        // Without AX permission, retain a geometry fallback for notched screens.
        // An explicit AX false prevents an ordinary maximized window matching it.
        return window.isNativeFullScreen != false
            && display.topSafeAreaInset.isFinite
            && display.topSafeAreaInset > 0
            && display.topSafeAreaInset < display.bounds.height
            && window.bounds.minY <= display.bounds.minY + display.topSafeAreaInset + edgeTolerance
            && window.bounds.maxY >= display.bounds.maxY - edgeTolerance
    }

    private static func spansPhysicalHeight(_ window: CGRect, of display: CGRect) -> Bool {
        window.minY <= display.minY + edgeTolerance
            && window.maxY >= display.maxY - edgeTolerance
    }

    private static func isValid(_ frame: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0
            && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
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

@MainActor
final class FullScreenDisplayMonitor {
    typealias WindowSnapshotProvider = @Sendable ([FullScreenDisplayGeometry]) -> [FullScreenWindowSnapshot]?

    private static let transitionRefreshDelays: [TimeInterval] = [0.15, 0.4, 0.8, 1.4]

    var onFullScreenDisplaysChange: ((Set<CGDirectDisplayID>) -> Void)?

    private let workspaceNotificationCenter: NotificationCenter
    private let currentProcessIdentifier: pid_t
    private let windowSnapshotProvider: WindowSnapshotProvider
    private let refreshInterval: TimeInterval
    private let snapshotQueue = DispatchQueue(label: "com.baikaihao.EchoDock.full-screen-windows", qos: .utility)
    private var displayGeometries: [FullScreenDisplayGeometry] = []
    private var fullScreenDisplayIDs: Set<CGDirectDisplayID> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshWorkItems: [DispatchWorkItem] = []
    private var timer: Timer?
    private var refreshGeneration: UInt64 = 0
    private var isRefreshInFlight = false
    private var isRefreshRequested = false
    private var missingDisplayIDs: Set<CGDirectDisplayID> = []
    private var isStarted = false

    init(
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        refreshInterval: TimeInterval = 0.75,
        windowSnapshotProvider: @escaping WindowSnapshotProvider = { displays in
            SystemFullScreenWindowSnapshotProvider.currentSnapshots(displays: displays)
        }
    ) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.currentProcessIdentifier = currentProcessIdentifier
        self.refreshInterval = refreshInterval
        self.windowSnapshotProvider = windowSnapshotProvider
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let center = workspaceNotificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleRefresh()
                }
            }
        }

        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestRefresh() }
        }
        timer.tolerance = refreshInterval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        scheduleRefresh()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        refreshGeneration &+= 1
        isRefreshRequested = false
        cancelScheduledRefreshes()
        timer?.invalidate()
        timer = nil
        let center = workspaceNotificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        displayGeometries.removeAll()
        missingDisplayIDs.removeAll()
        publish([])
    }

    func updateDisplays(_ displays: [DisplayDescriptor]) {
        let screensByID = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { (CGDirectDisplayID($0.uint32Value), screen) }
        })
        let geometries = displays.compactMap { display -> FullScreenDisplayGeometry? in
            guard !display.isMirrorSecondary else { return nil }
            return FullScreenDisplayGeometry(
                displayID: display.displayID,
                bounds: CGDisplayBounds(display.displayID),
                topSafeAreaInset: screensByID[display.displayID]?.safeAreaInsets.top ?? 0
            )
        }
        updateDisplayGeometries(geometries)
    }

    func updateDisplayGeometries(_ geometries: [FullScreenDisplayGeometry]) {
        guard geometries != displayGeometries else { return }
        refreshGeneration &+= 1
        displayGeometries = geometries
        missingDisplayIDs.removeAll()
        publish(fullScreenDisplayIDs.intersection(geometries.map(\.displayID)))
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard isStarted else { return }
        // A snapshot from before a Space or application switch is stale even
        // when the display geometry itself has not changed.
        refreshGeneration &+= 1
        cancelScheduledRefreshes()
        requestRefresh()
        // Space notifications can precede the end of the animation. Recheck
        // through the transition instead of relying on one fixed-delay sample.
        refreshWorkItems = Self.transitionRefreshDelays.map { delay in
            let workItem = DispatchWorkItem { [weak self] in self?.requestRefresh() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return workItem
        }
    }

    private func cancelScheduledRefreshes() {
        refreshWorkItems.forEach { $0.cancel() }
        refreshWorkItems.removeAll()
    }

    private func requestRefresh() {
        guard isStarted, !displayGeometries.isEmpty else { return }
        guard !isRefreshInFlight else {
            isRefreshRequested = true
            return
        }
        isRefreshInFlight = true
        isRefreshRequested = false
        let generation = refreshGeneration
        let geometries = displayGeometries
        let provider = windowSnapshotProvider
        let processIdentifier = currentProcessIdentifier

        // AX IPC can wait on another app. Keep both it and the window-list
        // query off the UI thread, with at most one snapshot in flight.
        snapshotQueue.async { [weak self] in
            let displayIDs = provider(geometries).map { windows in
                FullScreenWindowPolicy.fullScreenDisplayIDs(
                    displays: geometries,
                    windows: windows,
                    excludingProcessIdentifier: processIdentifier
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isRefreshInFlight = false
                guard self.isStarted else { return }
                if generation == self.refreshGeneration, let displayIDs {
                    // Hide immediately; require two successful misses to restore
                    // so a transient empty list during an animation cannot flash.
                    let missing = self.fullScreenDisplayIDs.subtracting(displayIDs)
                    let retained = missing.subtracting(self.missingDisplayIDs)
                    self.missingDisplayIDs = missing
                    self.publish(displayIDs.union(retained))
                }
                if self.isRefreshRequested || generation != self.refreshGeneration {
                    self.requestRefresh()
                }
            }
        }
    }

    private func publish(_ nextDisplayIDs: Set<CGDirectDisplayID>) {
        guard nextDisplayIDs != fullScreenDisplayIDs else { return }
        fullScreenDisplayIDs = nextDisplayIDs
        onFullScreenDisplaysChange?(nextDisplayIDs)
    }

    deinit {
        timer?.invalidate()
        refreshWorkItems.forEach { $0.cancel() }
        workspaceObservers.forEach(workspaceNotificationCenter.removeObserver)
    }
}
