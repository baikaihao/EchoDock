import AppKit
import ApplicationServices
import CoreFoundation
import CoreGraphics

/// A session event tap requires Accessibility access and can affect mouse
/// events at the edge of non-target displays.
enum NativeDockLockStatus: Equatable {
    case disabled
    case waitingForAccessibility
    case targetUnavailable
    case relocating
    case active
    case verificationFailed
    case unavailable

    var isActive: Bool {
        self == .active
    }
}

enum NativeDockLockEdge: String, Equatable {
    case bottom
    case left
    case right
}

enum NativeDockRelocationInputPolicy {
    static func canRelocate(pressedMouseButtons: Int) -> Bool {
        pressedMouseButtons == 0
    }
}

struct NativeDockLockDisplayGeometry: Equatable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let isMirrorSecondary: Bool
}

struct NativeDockLockScreenMetrics: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
}

struct NativeDockWindowGeometry: Equatable {
    let frame: CGRect
}

enum NativeDockDisplayDetector {
    static func displayID(
        for windows: [NativeDockWindowGeometry],
        displays: [NativeDockLockDisplayGeometry],
        edge: NativeDockLockEdge
    ) -> CGDirectDisplayID? {
        var bestMatch: (displayID: CGDirectDisplayID, score: CGFloat)?

        for window in windows where window.frame.width > 1 && window.frame.height > 1 {
            for display in displays where !display.isMirrorSecondary {
                let crossAxisOverlap = overlapLength(
                    window.frame,
                    display.frame,
                    edge: edge
                )
                guard crossAxisOverlap > 1 else { continue }

                let edgeDistance = distanceToEdge(
                    window.frame,
                    display.frame,
                    edge: edge
                )
                let minorDimension = edge == .bottom
                    ? window.frame.height
                    : window.frame.width
                let majorDimension = edge == .bottom
                    ? window.frame.width
                    : window.frame.height
                let displayMinorDimension = edge == .bottom
                    ? display.frame.height
                    : display.frame.width
                let maximumDockThickness = min(
                    360,
                    max(220, displayMinorDimension * 0.28)
                )
                let shapeMatches = edge == .bottom
                    ? window.frame.width >= window.frame.height
                    : window.frame.height >= window.frame.width
                guard shapeMatches,
                      majorDimension >= 48,
                      minorDimension <= maximumDockThickness else { continue }
                guard edgeDistance <= max(160, minorDimension * 2) else { continue }

                let intersection = window.frame.intersection(display.frame)
                let intersectionArea = intersection.isNull
                    ? 0
                    : intersection.width * intersection.height
                let windowArea = max(1, window.frame.width * window.frame.height)
                let score = (intersectionArea / windowArea) * 1_000
                    + crossAxisOverlap * 2
                    + 100
                    - edgeDistance * 4

                if bestMatch == nil || score > bestMatch!.score {
                    bestMatch = (display.displayID, score)
                }
            }
        }

        return bestMatch?.displayID
    }

    private static func overlapLength(
        _ window: CGRect,
        _ display: CGRect,
        edge: NativeDockLockEdge
    ) -> CGFloat {
        switch edge {
        case .bottom:
            return max(0, min(window.maxX, display.maxX) - max(window.minX, display.minX))
        case .left, .right:
            return max(0, min(window.maxY, display.maxY) - max(window.minY, display.minY))
        }
    }

    private static func distanceToEdge(
        _ window: CGRect,
        _ display: CGRect,
        edge: NativeDockLockEdge
    ) -> CGFloat {
        switch edge {
        case .bottom:
            return min(
                abs(window.minY - display.maxY),
                abs(window.maxY - display.maxY)
            )
        case .left:
            return min(
                abs(window.minX - display.minX),
                abs(window.maxX - display.minX)
            )
        case .right:
            return min(
                abs(window.minX - display.maxX),
                abs(window.maxX - display.maxX)
            )
        }
    }
}

/// Pure geometry used by the event tap and by unit tests.  It deliberately
/// contains no WindowServer or Accessibility calls.
enum NativeDockLockGeometry {
    private struct Interval {
        let lower: CGFloat
        let upper: CGFloat

        var range: ClosedRange<CGFloat> { lower...upper }
    }

    static func triggerZone(
        for frame: CGRect,
        edge: NativeDockLockEdge,
        depth: CGFloat = 10
    ) -> CGRect {
        let clampedDepth = max(1, depth)
        switch edge {
        case .bottom:
            return CGRect(
                x: frame.minX,
                y: frame.maxY - clampedDepth,
                width: frame.width,
                height: clampedDepth
            )
        case .left:
            return CGRect(
                x: frame.minX,
                y: frame.minY,
                width: clampedDepth,
                height: frame.height
            )
        case .right:
            return CGRect(
                x: frame.maxX - clampedDepth,
                y: frame.minY,
                width: clampedDepth,
                height: frame.height
            )
        }
    }

    static func shouldBlock(
        point: CGPoint,
        displays: [NativeDockLockDisplayGeometry],
        targetDisplayID: CGDirectDisplayID,
        edge: NativeDockLockEdge,
        depth: CGFloat = 10
    ) -> Bool {
        protectedDisplay(
            at: point,
            displays: displays,
            targetDisplayID: targetDisplayID,
            edge: edge,
            depth: depth
        ) != nil
    }

    private static func protectedDisplay(
        at point: CGPoint,
        displays: [NativeDockLockDisplayGeometry],
        targetDisplayID: CGDirectDisplayID,
        edge: NativeDockLockEdge,
        depth: CGFloat
    ) -> NativeDockLockDisplayGeometry? {
        displays.first { display in
            guard display.displayID != targetDisplayID,
                  !display.isMirrorSecondary else { return false }
            guard containsInclusive(
                triggerZone(for: display.frame, edge: edge, depth: depth),
                point
            ) else {
                return false
            }

            let coordinate = edge == .bottom ? point.x : point.y
            return exposedIntervals(for: display, among: displays, edge: edge).contains {
                $0.contains(coordinate)
            }
        }
    }

    private static func containsInclusive(_ rect: CGRect, _ point: CGPoint) -> Bool {
        rect.width > 0
            && rect.height > 0
            && point.x >= rect.minX
            && point.x <= rect.maxX
            && point.y >= rect.minY
            && point.y <= rect.maxY
    }

    /// Returns the portions of a display edge that are physically exposed.
    /// A display touching that edge (including the selected target display)
    /// owns the shared boundary, so the shared interval must remain passable
    /// for normal cross-display mouse movement.
    static func exposedIntervals(
        for display: NativeDockLockDisplayGeometry,
        among displays: [NativeDockLockDisplayGeometry],
        edge: NativeDockLockEdge,
        tolerance: CGFloat = 1.5
    ) -> [ClosedRange<CGFloat>] {
        let span = edge == .bottom
            ? Interval(lower: display.frame.minX, upper: display.frame.maxX)
            : Interval(lower: display.frame.minY, upper: display.frame.maxY)
        guard span.upper > span.lower else { return [] }

        var remaining = [span]
        let neighbors = displays.filter { other in
            guard other.displayID != display.displayID,
                  !other.isMirrorSecondary else { return false }
            switch edge {
            case .bottom:
                return abs(other.frame.minY - display.frame.maxY) <= tolerance
                    && rangesOverlap(
                        other.frame.minX...other.frame.maxX,
                        display.frame.minX...display.frame.maxX,
                        tolerance: tolerance
                    )
            case .left:
                return abs(other.frame.maxX - display.frame.minX) <= tolerance
                    && rangesOverlap(
                        other.frame.minY...other.frame.maxY,
                        display.frame.minY...display.frame.maxY,
                        tolerance: tolerance
                    )
            case .right:
                return abs(other.frame.minX - display.frame.maxX) <= tolerance
                    && rangesOverlap(
                        other.frame.minY...other.frame.maxY,
                        display.frame.minY...display.frame.maxY,
                        tolerance: tolerance
                    )
            }
        }

        for neighbor in neighbors {
            let overlap: Interval
            if edge == .bottom {
                overlap = Interval(
                    lower: max(span.lower, neighbor.frame.minX - tolerance),
                    upper: min(span.upper, neighbor.frame.maxX + tolerance)
                )
            } else {
                overlap = Interval(
                    lower: max(span.lower, neighbor.frame.minY - tolerance),
                    upper: min(span.upper, neighbor.frame.maxY + tolerance)
                )
            }
            guard overlap.upper > overlap.lower else { continue }

            var next: [Interval] = []
            for segment in remaining {
                if overlap.lower > segment.lower {
                    next.append(Interval(lower: segment.lower, upper: min(overlap.lower, segment.upper)))
                }
                if overlap.upper < segment.upper {
                    next.append(Interval(lower: max(overlap.upper, segment.lower), upper: segment.upper))
                }
            }
            remaining = next.filter { $0.upper - $0.lower > 0.5 }
            if remaining.isEmpty { break }
        }

        return remaining.map(\.range)
    }

    private static func rangesOverlap(
        _ lhs: ClosedRange<CGFloat>,
        _ rhs: ClosedRange<CGFloat>,
        tolerance: CGFloat
    ) -> Bool {
        lhs.upperBound + tolerance >= rhs.lowerBound
            && rhs.upperBound + tolerance >= lhs.lowerBound
    }

    static func relocationPoints(
        for frame: CGRect,
        edge: NativeDockLockEdge,
        edgeCoordinate: CGFloat? = nil,
        approachDistance: CGFloat = 50,
        steps: Int = 8,
        holdCount: Int = 8
    ) -> [CGPoint] {
        let safeSteps = max(1, steps)
        let safeHoldCount = max(0, holdCount)

        let target: CGPoint
        let approach: CGPoint
        switch edge {
        case .bottom:
            let x = min(max(edgeCoordinate ?? frame.midX, frame.minX + 1), frame.maxX - 1)
            target = CGPoint(x: x, y: frame.maxY - 1)
            let distance = min(max(1, approachDistance), max(1, frame.height - 2))
            approach = CGPoint(x: x, y: frame.maxY - distance)
        case .left:
            let y = min(max(edgeCoordinate ?? frame.midY, frame.minY + 1), frame.maxY - 1)
            target = CGPoint(x: frame.minX + 1, y: y)
            let distance = min(max(1, approachDistance), max(1, frame.width - 2))
            approach = CGPoint(x: frame.minX + distance, y: y)
        case .right:
            let y = min(max(edgeCoordinate ?? frame.midY, frame.minY + 1), frame.maxY - 1)
            target = CGPoint(x: frame.maxX - 1, y: y)
            let distance = min(max(1, approachDistance), max(1, frame.width - 2))
            approach = CGPoint(x: frame.maxX - distance, y: y)
        }

        var points = [approach]
        for index in 1...safeSteps {
            let progress = CGFloat(index) / CGFloat(safeSteps)
            points.append(
                CGPoint(
                    x: approach.x + (target.x - approach.x) * progress,
                    y: approach.y + (target.y - approach.y) * progress
                )
            )
        }
        points.append(contentsOf: Array(repeating: target, count: safeHoldCount))
        return points
    }

    /// Infer the Dock edge from the portion of each screen reserved by the
    /// system Dock.  This avoids writing Dock preferences.  If the Dock is
    /// hidden or the metrics are unavailable, bottom is the least surprising
    /// fallback because it is macOS's default orientation.
    static func inferEdge(
        from metrics: [NativeDockLockScreenMetrics],
        minimumGap: CGFloat = 2
    ) -> NativeDockLockEdge {
        var bestEdge: NativeDockLockEdge = .bottom
        var bestGap = minimumGap

        for metric in metrics {
            let gaps: [(NativeDockLockEdge, CGFloat)] = [
                (.bottom, metric.visibleFrame.minY - metric.frame.minY),
                (.left, metric.visibleFrame.minX - metric.frame.minX),
                (.right, metric.frame.maxX - metric.visibleFrame.maxX)
            ]
            for (edge, gap) in gaps where gap > bestGap {
                bestGap = gap
                bestEdge = edge
            }
        }
        return bestEdge
    }

    static func edge(forDockOrientation rawValue: String?) -> NativeDockLockEdge? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        return NativeDockLockEdge(rawValue: value)
    }
}

/// Keeps the system Dock on one display by blocking only its edge-trigger
/// mouse movements on other displays.  This is the same class of mechanism
/// used by several open-source Dock lock utilities. It is enabled only while
/// the user has selected a fixed native-Dock target.
@MainActor
final class NativeDockLockService {
    typealias WindowSnapshotProvider = (AccessibilityOperationBudget) -> NativeDockWindowSnapshot?

    private let snapshotWorker: AccessibilityWorkQueue<WindowSnapshotProvider>
    private let snapshotBudget = AccessibilityOperationBudget()
    private let isAccessibilityGranted: () -> Bool

    init(
        windowSnapshotProvider: @escaping WindowSnapshotProvider = { NativeDockWindowSnapshotProvider(budget: $0).snapshots() },
        isAccessibilityGranted: @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        snapshotWorker = AccessibilityWorkQueue(backend: windowSnapshotProvider, name: "com.baikaihao.EchoDock.native-dock-snapshots")
        self.isAccessibilityGranted = isAccessibilityGranted
    }
    private static let dockDomain = "com.apple.dock" as CFString
    private static let dockOrientationKey = "orientation" as CFString
    private static let relocationInputRetryDelay: TimeInterval = 0.15

    private(set) var status: NativeDockLockStatus = .disabled {
        didSet {
            guard oldValue != status else { return }
            onStatusChange?(status)
            NotificationCenter.default.post(
                name: .echoDockNativeDockLockStatusDidChange,
                object: self
            )
        }
    }

    private(set) var currentDockDisplayID: CGDirectDisplayID? {
        didSet {
            guard oldValue != currentDockDisplayID else { return }
            NotificationCenter.default.post(
                name: .echoDockNativeDockLockStatusDidChange,
                object: self
            )
        }
    }

    var onStatusChange: ((NativeDockLockStatus) -> Void)?
    var onProtectedEdgePointerMotion: (@MainActor (CGPoint, Int) -> Void)?

    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var dockPreferenceObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRunning = false
    private var isEnabled = false
    private var isRelocating = false
    private var targetDisplayID: CGDirectDisplayID?
    private var displays: [NativeDockLockDisplayGeometry] = []
    private var edge: NativeDockLockEdge = .bottom
    private var relocationGeneration = 0
    private var relocationSavedPosition: CGPoint?
    private var pendingProtectedEdgePointerMotion: (location: CGPoint, pressedButtons: Int)?
    private var isProtectedEdgePointerMotionScheduled = false
    private var promptIssued = false
    private let syntheticEventMarker: Int64 = 0x4D554C5449444F43 // "MULTIDOC"

    deinit {
        permissionTimer?.invalidate()
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        observers.forEach { $0.center.removeObserver($0.token) }
        if let dockPreferenceObserver { DistributedNotificationCenter.default().removeObserver(dockPreferenceObserver) }
    }

    func start() {
        guard observers.isEmpty else { return }

        isRunning = true
        startPermissionTimer()

        let defaultCenter = NotificationCenter.default
        let screenToken = defaultCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }
        observers.append((defaultCenter, screenToken))

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let wakeToken = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRelocation(after: 2)
        }
        observers.append((workspaceCenter, wakeToken))
        let sessionToken = workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRelocation(after: 1)
        }
        observers.append((workspaceCenter, sessionToken))

        dockPreferenceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.dock.prefchanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDockPreferenceChange()
        }
    }

    /// Applies the current preference and display topology.  Passing
    /// `enabled == false` tears down the tap and does not request permission.
    func configure(
        enabled: Bool,
        targetDisplayID: CGDirectDisplayID?,
        displays: [DisplayDescriptor]
    ) {
        let geometry = displays.map { descriptor in
            NativeDockLockDisplayGeometry(
                displayID: descriptor.displayID,
                // CGEvent locations and CGDisplayBounds share the global
                // Core Graphics coordinate space.
                frame: CGDisplayBounds(descriptor.displayID),
                isMirrorSecondary: descriptor.isMirrorSecondary
            )
        }
        configure(
            enabled: enabled,
            targetDisplayID: targetDisplayID,
            displays: geometry,
            edge: currentEdge()
        )
    }

    @discardableResult
    func refreshCurrentDockDisplay(displays: [DisplayDescriptor]) -> CGDirectDisplayID? {
        let geometry = displays.map {
            NativeDockLockDisplayGeometry(
                displayID: $0.displayID,
                frame: CGDisplayBounds($0.displayID),
                isMirrorSecondary: $0.isMirrorSecondary
            )
        }
        let observedEdge = currentEdge()
        return refreshCurrentDockDisplay(displays: geometry, edge: observedEdge)
    }

    @discardableResult
    func refreshCurrentDockDisplay(displays: [NativeDockLockDisplayGeometry], edge: NativeDockLockEdge) -> CGDirectDisplayID? {
        detectCurrentDockDisplay(displays: displays, edge: edge) { [weak self] observed, isFresh in
            if isFresh { self?.currentDockDisplayID = observed }
        }
        return currentDockDisplayID
    }

    /// Internal/value-oriented entry point useful for deterministic tests and
    /// for callers that already have CG display geometry.
    func configure(
        enabled: Bool,
        targetDisplayID: CGDirectDisplayID?,
        displays: [NativeDockLockDisplayGeometry],
        edge: NativeDockLockEdge
    ) {
        let previousStatus = status
        let targetChanged = self.targetDisplayID != targetDisplayID
        let geometryChanged = self.displays != displays || self.edge != edge
        if targetChanged || geometryChanged || self.isEnabled != enabled { snapshotWorker.cancelAll() }
        self.displays = displays
        self.edge = edge

        if !enabled {
            isEnabled = false
            self.targetDisplayID = nil
            stopEventTap()
            cancelRelocation()
            promptIssued = false
            status = .disabled
            if isRunning {
                startPermissionTimer()
            }
            return
        }

        isEnabled = true
        self.targetDisplayID = targetDisplayID

        guard let targetDisplayID,
              displays.contains(where: {
                  $0.displayID == targetDisplayID && !$0.isMirrorSecondary
              }) else {
            stopEventTap()
            cancelRelocation()
            status = .targetUnavailable
            startPermissionTimer()
            return
        }

        guard isAccessibilityGranted() else {
            stopEventTap()
            cancelRelocation()
            currentDockDisplayID = nil
            status = .waitingForAccessibility
            requestAccessibilityIfNeeded()
            startPermissionTimer()
            return
        }

        startEventTapIfNeeded()
        if eventTap != nil {
            startPermissionTimer()
            reconcileObservedDock(
                forceRelocation: targetChanged
                    || geometryChanged
                    || previousStatus == .disabled
                    || previousStatus == .waitingForAccessibility
                    || previousStatus == .targetUnavailable
                    || previousStatus == .verificationFailed
                    || previousStatus == .unavailable
            )
        } else {
            status = .unavailable
            startPermissionTimer()
        }
    }

    func stop() {
        snapshotWorker.cancelAll()
        isRunning = false
        isEnabled = false
        targetDisplayID = nil
        displays.removeAll()
        pendingProtectedEdgePointerMotion = nil
        stopPermissionTimer()
        stopEventTap()
        cancelRelocation()
        promptIssued = false
        status = .disabled

        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers.removeAll()
        if let dockPreferenceObserver {
            DistributedNotificationCenter.default().removeObserver(dockPreferenceObserver)
        }
        dockPreferenceObserver = nil
    }

    private func currentEdge() -> NativeDockLockEdge {
        _ = CFPreferencesSynchronize(
            Self.dockDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        let orientation = CFPreferencesCopyValue(
            Self.dockOrientationKey,
            Self.dockDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? String
        if let preferredEdge = NativeDockLockGeometry.edge(forDockOrientation: orientation) {
            return preferredEdge
        }

        let metrics = NSScreen.screens.map {
            NativeDockLockScreenMetrics(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        return NativeDockLockGeometry.inferEdge(from: metrics)
    }

    private func handleDockPreferenceChange() {
        guard isEnabled else { return }
        let nextEdge = currentEdge()
        guard nextEdge != edge else { return }
        edge = nextEdge
        cancelRelocation()
        scheduleRelocation(after: 0.18)
    }

    private func handleScreenChange() {
        guard isRunning else { return }

        // Refresh frames and mirror state without waiting for the controller's
        // next topology pass. The stable target ID is still supplied by the
        // controller on the next reconcile if a display was replaced.
        let current = NSScreen.screens.compactMap { screen -> NativeDockLockDisplayGeometry? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let mirroredID = CGDisplayMirrorsDisplay(displayID)
            return NativeDockLockDisplayGeometry(
                displayID: displayID,
                frame: CGDisplayBounds(displayID),
                isMirrorSecondary: mirroredID != kCGNullDirectDisplay
            )
        }
        let nextEdge = currentEdge()
        let shouldLock = isEnabled
        configure(
            enabled: shouldLock,
            targetDisplayID: targetDisplayID,
            displays: current,
            edge: nextEdge
        )
    }

    private func requestAccessibilityIfNeeded() {
        guard !promptIssued else { return }
        promptIssued = true
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    private func startPermissionTimer() {
        guard permissionTimer == nil else { return }
        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(permissionTimerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func stopPermissionTimer() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    @objc private func permissionTimerFired() {
        guard isRunning else {
            stopPermissionTimer()
            return
        }
        if !isEnabled {
            let observedEdge = currentEdge()
            edge = observedEdge
            detectCurrentDockDisplay(displays: displays, edge: observedEdge) { [weak self] observed, isFresh in
            if isFresh { self?.currentDockDisplayID = observed }
        }
            return
        }
        guard let targetDisplayID,
              displays.contains(where: {
                  $0.displayID == targetDisplayID && !$0.isMirrorSecondary
              }) else {
            cancelRelocation()
            status = .targetUnavailable
            return
        }
        guard isAccessibilityGranted() else {
            stopEventTap()
            cancelRelocation()
            currentDockDisplayID = nil
            status = .waitingForAccessibility
            return
        }

        let nextEdge = currentEdge()
        let edgeChanged = nextEdge != edge
        if edgeChanged {
            edge = nextEdge
            cancelRelocation()
        }

        startEventTapIfNeeded()
        if eventTap != nil {
            // A complete synthetic approach plus AX verification takes longer
            // than this timer's interval. Polling during that lifecycle would
            // cancel the in-flight sequence before it can finish.
            guard edgeChanged || (status != .relocating && !isRelocating) else {
                return
            }
            reconcileObservedDock(
                forceRelocation: edgeChanged
            )
            startPermissionTimer()
        } else {
            status = .unavailable
            startPermissionTimer()
        }
    }

    private func startEventTapIfNeeded() {
        guard isEnabled, eventTap == nil, isAccessibilityGranted() else { return }

        let eventMask = (CGEventMask(1) << CGEventType.mouseMoved.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.tapDisabledByTimeout.rawValue)
            | (CGEventMask(1) << CGEventType.tapDisabledByUserInput.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let service = Unmanaged<NativeDockLockService>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                return MainActor.assumeIsolated { service.handle(eventType: type, event: event) }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopEventTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func handle(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let pressedMouseButtons = NSEvent.pressedMouseButtons
        guard NativeDockEventPolicy.canBeBlocked(eventType) else {
            return Unmanaged.passUnretained(event)
        }

        guard isEnabled else {
            return Unmanaged.passUnretained(event)
        }

        if isRelocating {
            let marker = event.getIntegerValueField(.eventSourceUserData)
            return marker == syntheticEventMarker ? Unmanaged.passUnretained(event) : nil
        }

        guard let targetDisplayID else {
            return Unmanaged.passUnretained(event)
        }

        let quartzLocation = event.location
        guard NativeDockLockGeometry.shouldBlock(
            point: quartzLocation,
            displays: displays,
            targetDisplayID: targetDisplayID,
            edge: edge
        ) else {
            return Unmanaged.passUnretained(event)
        }

        // A blocked session-tap event never reaches AppKit's global monitor.
        // unflippedLocation uses the same main-display lower-left origin as
        // AppKit global screen coordinates. NSEvent.mouseLocation is racy here
        // because AppKit has not published this event yet.
        enqueueProtectedEdgePointerMotion(
            location: event.unflippedLocation,
            pressedButtons: pressedMouseButtons
        )

        guard let deliveredEvent = NativeDockProtectedEdgeEventRouter.route(
            event,
            pressedMouseButtons: pressedMouseButtons
        ) else { return nil }
        return Unmanaged.passUnretained(deliveredEvent)
    }

    private func enqueueProtectedEdgePointerMotion(
        location: CGPoint,
        pressedButtons: Int
    ) {
        pendingProtectedEdgePointerMotion = (location, pressedButtons)
        guard !isProtectedEdgePointerMotionScheduled else { return }
        isProtectedEdgePointerMotionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let sample = self.pendingProtectedEdgePointerMotion
            self.pendingProtectedEdgePointerMotion = nil
            self.isProtectedEdgePointerMotionScheduled = false
            guard self.isRunning, self.isEnabled, let sample else { return }
            MainActor.assumeIsolated {
                self.onProtectedEdgePointerMotion?(
                    sample.location,
                    sample.pressedButtons
                )
            }
        }
    }

    private func scheduleRelocation(after delay: TimeInterval) {
        guard isEnabled,
              targetDisplayID != nil,
              eventTap != nil,
              AXIsProcessTrusted() else { return }
        if status == .relocating || isRelocating {
            cancelRelocation()
        }
        status = .relocating
        relocationGeneration &+= 1
        let generation = relocationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.relocationGeneration == generation else { return }
            self.beginRelocation(generation: generation)
        }
    }

    private func cancelRelocation() {
        relocationGeneration &+= 1
        if let relocationSavedPosition {
            CGWarpMouseCursorPosition(relocationSavedPosition)
            self.relocationSavedPosition = nil
        }
        if isRelocating {
            NSCursor.unhide()
            isRelocating = false
        }
    }

    private func beginRelocation(generation: Int) {
        guard isEnabled,
              !isRelocating,
              eventTap != nil,
              AXIsProcessTrusted(),
              let targetDisplayID,
              let target = displays.first(where: { $0.displayID == targetDisplayID }) else {
            if !AXIsProcessTrusted() {
                currentDockDisplayID = nil
                status = .waitingForAccessibility
            } else if self.targetDisplayID == nil
                        || !displays.contains(where: {
                            $0.displayID == self.targetDisplayID && !$0.isMirrorSecondary
                        }) {
                status = .targetUnavailable
            } else {
                status = .unavailable
            }
            return
        }
        guard NativeDockRelocationInputPolicy.canRelocate(
            pressedMouseButtons: NSEvent.pressedMouseButtons
        ) else {
            scheduleRelocation(after: Self.relocationInputRetryDelay)
            return
        }
        guard let savedPosition = CGEvent(source: nil)?.location,
              let source = CGEventSource(stateID: .hidSystemState) else {
            status = .unavailable
            return
        }

        let exposedIntervals = NativeDockLockGeometry.exposedIntervals(
            for: target,
            among: displays,
            edge: edge
        )
        guard let targetInterval = exposedIntervals.max(by: { lhs, rhs in
            (lhs.upperBound - lhs.lowerBound) < (rhs.upperBound - rhs.lowerBound)
        }) else {
            // A target edge fully covered by another display is not a safe
            // place to synthesize a Dock trigger. Stop intercepting rather
            // than moving the user's cursor into an internal display seam.
            stopEventTap()
            status = .unavailable
            return
        }
        let edgeCoordinate = (targetInterval.lowerBound + targetInterval.upperBound) / 2

        let points = NativeDockLockGeometry.relocationPoints(
            for: target.frame,
            edge: edge,
            edgeCoordinate: edgeCoordinate
        )
        guard !points.isEmpty else {
            status = .unavailable
            return
        }

        relocationSavedPosition = savedPosition
        isRelocating = true
        NSCursor.hide()
        sendRelocationStep(
            points: points,
            index: 0,
            savedPosition: savedPosition,
            source: source,
            generation: generation
        )
    }

    private func sendRelocationStep(
        points: [CGPoint],
        index: Int,
        savedPosition: CGPoint,
        source: CGEventSource,
        generation: Int
    ) {
        guard isEnabled,
              isRelocating,
              relocationGeneration == generation,
              index < points.count else {
            finishRelocation(savedPosition: savedPosition, generation: generation)
            return
        }
        guard NativeDockRelocationInputPolicy.canRelocate(
            pressedMouseButtons: NSEvent.pressedMouseButtons
        ) else {
            cancelRelocation()
            scheduleRelocation(after: Self.relocationInputRetryDelay)
            return
        }

        let point = points[index]
        CGWarpMouseCursorPosition(point)
        if let event = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) {
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }

        let delay: TimeInterval = index == 0 ? 0.03 : 0.08
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.sendRelocationStep(
                points: points,
                index: index + 1,
                savedPosition: savedPosition,
                source: source,
                generation: generation
            )
        }
    }

    private func finishRelocation(savedPosition: CGPoint, generation: Int) {
        guard isRelocating else { return }
        CGWarpMouseCursorPosition(relocationSavedPosition ?? savedPosition)
        relocationSavedPosition = nil
        NSCursor.unhide()
        isRelocating = false
        guard isEnabled, relocationGeneration == generation else { return }
        verifyRelocation(generation: generation, attemptsRemaining: 3)
    }

    private func reconcileObservedDock(forceRelocation: Bool) {
        guard eventTap != nil, let targetDisplayID else { return }
        detectCurrentDockDisplay(displays: displays, edge: edge) { [weak self] observed, isFresh in
            guard let self, isFresh, self.eventTap != nil, self.targetDisplayID == targetDisplayID else { return }
            self.currentDockDisplayID = observed
            if observed == targetDisplayID {
                self.cancelRelocation()
                self.status = .active
                return
            }
            guard forceRelocation || (self.status != .relocating && self.status != .verificationFailed) else { return }
            self.cancelRelocation()
            self.scheduleRelocation(after: 0.15)
        }
    }

    private func verifyRelocation(generation: Int, attemptsRemaining: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.isEnabled, generation == self.relocationGeneration,
                  let targetDisplayID = self.targetDisplayID else { return }
            self.detectCurrentDockDisplay(displays: self.displays, edge: self.edge) { [weak self] observed, isFresh in
                guard let self, self.isEnabled, generation == self.relocationGeneration else { return }
                if isFresh { self.currentDockDisplayID = observed }
                if isFresh && observed == targetDisplayID {
                    self.status = .active
                } else if attemptsRemaining > 1 {
                    self.verifyRelocation(generation: generation, attemptsRemaining: attemptsRemaining - 1)
                } else {
                    self.status = .verificationFailed
                }
            }
        }
    }

    private func detectCurrentDockDisplay(
        displays: [NativeDockLockDisplayGeometry],
        edge: NativeDockLockEdge,
        completion: @escaping @MainActor (CGDirectDisplayID?, Bool) -> Void
    ) {
        guard isAccessibilityGranted() else {
            snapshotWorker.cancelAll()
            currentDockDisplayID = nil
            completion(nil, true)
            return
        }
        let budget = snapshotBudget
        snapshotWorker.submit(key: "snapshot", priority: .low, work: { provider, isCurrent in
            budget.begin(duration: 0.5, isCurrent: isCurrent)
            return provider(budget)
        }) { [weak self] snapshots in
            guard let self else { return }
            guard let snapshots else { completion(self.currentDockDisplayID, false); return }
            completion(snapshots.displayID(displays: displays, edge: edge), true)
        }
    }
}
