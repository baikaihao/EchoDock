import AppKit
import ApplicationServices

struct WindowReservationInput: Equatable {
    var revision: UInt64 = 0
    var isConfigured = false
    var geometries: [WindowReservationDisplayGeometry] = []
    var allDisplayFrames: [CGRect] = []
    var snapRegions: [WindowEdgeSnapRegion] = []
}

/// A value snapshot is the only shared state between AppKit and the AX thread.
final class WindowReservationContext {
    private let lock = NSLock()
    private var value = WindowReservationInput()

    var current: WindowReservationInput {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ next: WindowReservationInput) {
        lock.lock()
        defer { lock.unlock() }
        var next = next
        next.revision = value.revision
        guard next != value else { return }
        next.revision &+= 1
        value = next
    }
}

@MainActor
final class WindowReservationService {
    typealias DisplayEnabledProvider = (DisplayIdentity) -> Bool
    typealias ReservationHeightProvider = (DisplayDescriptor) -> CGFloat
    typealias SnapRegionsProvider = () -> [WindowEdgeSnapRegion]

    private let topologyProvider: DisplayTopologyProvider
    private let workspace: NSWorkspace
    private let permissionService: AccessibilityPermissionService
    private let currentProcessIdentifier: pid_t
    private let isReservationEnabled: () -> Bool
    private let isDockEnabled: () -> Bool
    private let isAutoHide: () -> Bool
    private let isDisplayEnabled: DisplayEnabledProvider
    private let reservationHeightProvider: ReservationHeightProvider
    private let snapRegionsProvider: SnapRegionsProvider
    private let dockPositionProvider: () -> DockPosition
    private let context = WindowReservationContext()
    private var worker: WindowReservationWorker?
    private var executor: AccessibilityRunLoop?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    convenience init(
        preferences: PreferencesStore,
        topologyProvider: DisplayTopologyProvider = DisplayTopologyProvider(),
        workspace: NSWorkspace = .shared,
        permissionService: AccessibilityPermissionService = AccessibilityPermissionService(),
        snapRegionsProvider: @escaping SnapRegionsProvider = { [] }
    ) {
        self.init(
            topologyProvider: topologyProvider,
            workspace: workspace,
            permissionService: permissionService,
            isReservationEnabled: { preferences.reserveSpaceForWindows },
            isDockEnabled: { preferences.isEnabled },
            isAutoHide: { preferences.autoHide },
            isDisplayEnabled: { preferences.isDisplayEnabled($0) },
            reservationHeightProvider: {
                _ in WindowReservationMetrics.reservedHeight(iconSize: preferences.iconSize)
            },
            snapRegionsProvider: snapRegionsProvider,
            dockPositionProvider: { preferences.dockPosition }
        )
    }

    init(
        topologyProvider: DisplayTopologyProvider = DisplayTopologyProvider(),
        workspace: NSWorkspace = .shared,
        permissionService: AccessibilityPermissionService = AccessibilityPermissionService(),
        currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        isReservationEnabled: @escaping () -> Bool,
        isDockEnabled: @escaping () -> Bool,
        isAutoHide: @escaping () -> Bool,
        isDisplayEnabled: @escaping DisplayEnabledProvider,
        reservationHeightProvider: @escaping ReservationHeightProvider,
        snapRegionsProvider: @escaping SnapRegionsProvider = { [] },
        dockPositionProvider: @escaping () -> DockPosition = { .bottom }
    ) {
        self.topologyProvider = topologyProvider
        self.workspace = workspace
        self.permissionService = permissionService
        self.currentProcessIdentifier = currentProcessIdentifier
        self.isReservationEnabled = isReservationEnabled
        self.isDockEnabled = isDockEnabled
        self.isAutoHide = isAutoHide
        self.isDisplayEnabled = isDisplayEnabled
        self.reservationHeightProvider = reservationHeightProvider
        self.snapRegionsProvider = snapRegionsProvider
        self.dockPositionProvider = dockPositionProvider
    }

    func start() {
        guard worker == nil else { return }
        refreshInput()
        let executor = AccessibilityRunLoop()
        let worker = WindowReservationWorker(context: context, executor: executor, workspace: workspace,
                                             permissionService: permissionService, currentProcessIdentifier: currentProcessIdentifier)
        self.executor = executor
        self.worker = worker
        let center = NotificationCenter.default
        for name in [Notification.Name.echoDockPreferencesDidChange, .echoDockDisplayAssignmentsDidChange,
                     .echoDockDisplayTopologyDidChange, .echoDockWindowSnapRegionsDidChange,
                     NSApplication.didChangeScreenParametersNotification] {
            observe(center: center, name: name)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.screensDidWakeNotification, NSWorkspace.didActivateApplicationNotification] {
            observe(center: workspace.notificationCenter, name: name)
        }
        executor.perform { worker.start() }
    }

    func stop(completion: (() -> Void)? = nil) {
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        guard let worker, let executor else { completion?(); return }
        self.worker = nil
        self.executor = nil
        var disabled = context.current
        disabled.isConfigured = false
        context.update(disabled)
        executor.finish {
            worker.stop()
            DispatchQueue.main.async { completion?() }
        }
    }

    func reconcile(refreshAllWindows: Bool = false) {
        refreshInput()
        guard let worker else { return }
        executor?.perform { worker.reconcile(refreshAllWindows: refreshAllWindows) }
    }

    private func observe(center: NotificationCenter, name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        observers.append((center, token))
    }

    private func refreshInput() {
        let displays = topologyProvider.currentDisplays()
        context.update(WindowReservationInput(
            isConfigured: isReservationEnabled() && isDockEnabled() && !isAutoHide(),
            geometries: currentDisplayGeometries(),
            allDisplayFrames: displays.filter { !$0.isMirrorSecondary }.map { CGDisplayBounds($0.displayID) },
            snapRegions: snapRegionsProvider()
        ))
    }

    private func currentDisplayGeometries() -> [WindowReservationDisplayGeometry] {
        topologyProvider.currentDisplays().compactMap { descriptor in
            guard !descriptor.isMirrorSecondary,
                  isDisplayEnabled(descriptor.identity),
                  let screen = screen(displayID: descriptor.displayID) else {
                return nil
            }

            let accessibilityDisplayFrame = CGDisplayBounds(descriptor.displayID)
            let visibleFrame = accessibilityVisibleFrame(
                screen.visibleFrame,
                cocoaDisplayFrame: descriptor.frame,
                accessibilityDisplayFrame: accessibilityDisplayFrame
            )
            return WindowReservationDisplayGeometry(
                identity: descriptor.identity,
                frame: accessibilityDisplayFrame,
                visibleFrame: visibleFrame,
                reservedHeight: reservationHeightProvider(descriptor)
                    + (dockPositionProvider() == .top ? max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY) : 0),
                position: dockPositionProvider()
            )
        }
    }

    private func screen(displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID
        }
    }

    private func accessibilityVisibleFrame(
        _ cocoaVisibleFrame: CGRect,
        cocoaDisplayFrame: CGRect,
        accessibilityDisplayFrame: CGRect
    ) -> CGRect {
        let leftInset = max(0, cocoaVisibleFrame.minX - cocoaDisplayFrame.minX)
        let rightInset = max(0, cocoaDisplayFrame.maxX - cocoaVisibleFrame.maxX)
        let topInset = max(0, cocoaDisplayFrame.maxY - cocoaVisibleFrame.maxY)
        let bottomInset = max(0, cocoaVisibleFrame.minY - cocoaDisplayFrame.minY)
        return CGRect(
            x: accessibilityDisplayFrame.minX + leftInset,
            y: accessibilityDisplayFrame.minY + topInset,
            width: max(0, accessibilityDisplayFrame.width - leftInset - rightInset),
            height: max(0, accessibilityDisplayFrame.height - topInset - bottomInset)
        )
    }

}
