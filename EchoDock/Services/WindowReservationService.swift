import AppKit
import ApplicationServices
import CoreGraphics

private func windowReservationObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let service = Unmanaged<WindowReservationService>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    let notificationName = notification as String
    Task { @MainActor in
        service.receiveAccessibilityNotification(
            element: element,
            name: notificationName
        )
    }
}

@MainActor
final class WindowReservationService {
    typealias DisplayEnabledProvider = (DisplayIdentity) -> Bool
    typealias ReservationHeightProvider = (DisplayDescriptor) -> CGFloat

    private static let messagingTimeout: Float = 0.2
    private static let evaluationDelay: TimeInterval = 0.14
    private static let mutationSuppressionDuration: TimeInterval = 0.8

    private let topologyProvider: DisplayTopologyProvider
    private let workspace: NSWorkspace
    private let permissionService: AccessibilityPermissionService
    private let currentProcessIdentifier: pid_t
    private let isReservationEnabled: () -> Bool
    private let isDockEnabled: () -> Bool
    private let isAutoHide: () -> Bool
    private let isDisplayEnabled: DisplayEnabledProvider
    private let reservationHeightProvider: ReservationHeightProvider

    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationObservers: [NSObjectProtocol] = []
    private var observedApplications: [pid_t: ObservedApplication] = [:]
    private var managedWindows: [ManagedWindow] = []
    private var pendingEvaluations: [PendingEvaluation] = []
    private var mutationSuppressions: [MutationSuppression] = []
    private var displayGeometries: [WindowReservationDisplayGeometry] = []
    private var lifecycleGeneration: UInt64 = 0
    private var evaluationRevision: UInt64 = 0
    private var isStarted = false

    convenience init(
        preferences: PreferencesStore,
        topologyProvider: DisplayTopologyProvider = DisplayTopologyProvider(),
        workspace: NSWorkspace = .shared,
        permissionService: AccessibilityPermissionService = AccessibilityPermissionService()
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
            }
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
        reservationHeightProvider: @escaping ReservationHeightProvider
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
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        lifecycleGeneration &+= 1
        observeWorkspace()
        observeApplicationState()
        reconcile(refreshAllWindows: true)
    }

    func stop() {
        guard isStarted else { return }
        lifecycleGeneration &+= 1
        pendingEvaluations.removeAll()
        restoreManagedWindows()
        removeAllAccessibilityObservers()

        let workspaceCenter = workspace.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()
        applicationObservers.forEach(NotificationCenter.default.removeObserver)
        applicationObservers.removeAll()
        mutationSuppressions.removeAll()
        displayGeometries.removeAll()
        isStarted = false
    }

    /// Re-evaluates preference, display and running-application state. This is
    /// also the integration point for callers that already coalesce topology changes.
    func reconcile(refreshAllWindows: Bool = false) {
        guard isStarted else { return }
        let shouldBeActive = reservationShouldBeActive
        let nextDisplayGeometries = shouldBeActive
            ? currentDisplayGeometries()
            : []
        if !refreshAllWindows {
            if shouldBeActive,
               !nextDisplayGeometries.isEmpty,
               nextDisplayGeometries == displayGeometries {
                return
            }
            if !shouldBeActive,
               displayGeometries.isEmpty,
               managedWindows.isEmpty,
               observedApplications.isEmpty {
                return
            }
            if shouldBeActive,
               nextDisplayGeometries.isEmpty,
               displayGeometries.isEmpty,
               managedWindows.isEmpty,
               observedApplications.isEmpty {
                return
            }
        }

        lifecycleGeneration &+= 1
        pendingEvaluations.removeAll()

        guard shouldBeActive else {
            restoreManagedWindows()
            removeUnusedAccessibilityObservers()
            displayGeometries.removeAll()
            return
        }

        let previousDisplayGeometries = displayGeometries
        guard !nextDisplayGeometries.isEmpty else {
            restoreManagedWindows()
            removeAllAccessibilityObservers()
            displayGeometries.removeAll()
            return
        }

        let shouldRefreshApplications = refreshAllWindows
            || previousDisplayGeometries.isEmpty
        displayGeometries = nextDisplayGeometries
        if previousDisplayGeometries != nextDisplayGeometries {
            reconcileManagedWindows()
        }
        guard shouldRefreshApplications else { return }

        let applications = workspace.runningApplications.filter(isEligibleApplication)
        let runningProcessIdentifiers = Set(applications.map(\.processIdentifier))
        for processIdentifier in observedApplications.keys
            where !runningProcessIdentifiers.contains(processIdentifier) {
            removeAccessibilityObserver(processIdentifier: processIdentifier)
            managedWindows.removeAll { $0.processIdentifier == processIdentifier }
        }
        applications.forEach(ensureAccessibilityObserver)
        applications.forEach { refreshWindows(processIdentifier: $0.processIdentifier) }
    }

    fileprivate func receiveAccessibilityNotification(
        element: AXUIElement,
        name: String
    ) {
        guard isStarted else { return }
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier != currentProcessIdentifier else {
            return
        }

        switch name {
        case kAXWindowCreatedNotification,
             kAXFocusedWindowChangedNotification:
            refreshWindows(processIdentifier: processIdentifier)
        case kAXMovedNotification,
             kAXResizedNotification,
             kAXWindowMiniaturizedNotification,
             kAXWindowDeminiaturizedNotification:
            guard let frame = accessibilityFrame(of: element),
                  !consumeSuppressedMutation(for: element, currentFrame: frame) else {
                return
            }
            scheduleEvaluation(of: element, processIdentifier: processIdentifier)
        case kAXUIElementDestroyedNotification:
            removeTrackedWindow(element, processIdentifier: processIdentifier)
        default:
            break
        }
    }

    private var reservationShouldBeActive: Bool {
        reservationIsConfigured
            && permissionService.isGranted
    }

    private var reservationIsConfigured: Bool {
        isReservationEnabled() && isDockEnabled() && !isAutoHide()
    }

    private func observeWorkspace() {
        let center = workspace.notificationCenter
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleApplicationLaunch(notification)
                }
            },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleApplicationTermination(notification)
                }
            },
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleApplicationActivation(notification)
                }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reconcile(refreshAllWindows: true)
                }
            },
            center.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reconcile(refreshAllWindows: true)
                }
            }
        ]
    }

    private func observeApplicationState() {
        let center = NotificationCenter.default
        applicationObservers = [
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconcile() }
            },
            center.addObserver(
                forName: .echoDockPreferencesDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconcile() }
            },
            center.addObserver(
                forName: .echoDockDisplayAssignmentsDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reconcile(refreshAllWindows: true)
                }
            },
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reconcile(refreshAllWindows: true)
                }
            }
        ]
    }

    private func handleApplicationLaunch(_ notification: Notification) {
        refreshReservationActivationIfNeeded()
        guard reservationShouldBeActive,
              let application = runningApplication(from: notification),
              isEligibleApplication(application) else {
            return
        }
        ensureAccessibilityObserver(for: application)
        refreshWindows(processIdentifier: application.processIdentifier)
    }

    private func handleApplicationActivation(_ notification: Notification) {
        refreshReservationActivationIfNeeded()
        guard reservationShouldBeActive,
              let application = runningApplication(from: notification),
              isEligibleApplication(application) else {
            return
        }
        ensureAccessibilityObserver(for: application)
        refreshWindows(processIdentifier: application.processIdentifier)
    }

    private func refreshReservationActivationIfNeeded() {
        if reservationIsConfigured,
           permissionService.isGranted,
           displayGeometries.isEmpty {
            reconcile()
        } else if !reservationShouldBeActive, !managedWindows.isEmpty {
            reconcile()
        }
    }

    private func handleApplicationTermination(_ notification: Notification) {
        guard let application = runningApplication(from: notification) else { return }
        let processIdentifier = application.processIdentifier
        removeAccessibilityObserver(processIdentifier: processIdentifier)
        managedWindows.removeAll { $0.processIdentifier == processIdentifier }
        pendingEvaluations.removeAll { $0.processIdentifier == processIdentifier }
        mutationSuppressions.removeAll {
            processIdentifierOfElement($0.element) == processIdentifier
        }
    }

    private func runningApplication(from notification: Notification) -> NSRunningApplication? {
        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    private func isEligibleApplication(_ application: NSRunningApplication) -> Bool {
        !application.isTerminated
            && application.activationPolicy == .regular
            && application.processIdentifier != currentProcessIdentifier
    }

    private func ensureAccessibilityObserver(for application: NSRunningApplication) {
        let processIdentifier = application.processIdentifier
        guard observedApplications[processIdentifier] == nil,
              processIdentifier != currentProcessIdentifier else {
            return
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetMessagingTimeout(applicationElement, Self.messagingTimeout)
        var observer: AXObserver?
        guard AXObserverCreate(
            processIdentifier,
            windowReservationObserverCallback,
            &observer
        ) == .success,
        let observer else {
            return
        }

        let observation = ObservedApplication(
            processIdentifier: processIdentifier,
            applicationElement: applicationElement,
            observer: observer
        )
        observedApplications[processIdentifier] = observation
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        addNotification(
            kAXWindowCreatedNotification as String,
            element: applicationElement,
            observation: observation
        )
        addNotification(
            kAXFocusedWindowChangedNotification as String,
            element: applicationElement,
            observation: observation
        )
    }

    private func refreshWindows(processIdentifier: pid_t) {
        guard let observation = observedApplications[processIdentifier] else { return }
        let windows = accessibilityElements(
            of: observation.applicationElement,
            attribute: kAXWindowsAttribute as String
        )
        for window in windows {
            registerWindowIfNeeded(window, observation: observation)
            scheduleEvaluation(of: window, processIdentifier: processIdentifier)
        }
    }

    private func registerWindowIfNeeded(
        _ window: AXUIElement,
        observation: ObservedApplication
    ) {
        guard !observation.windows.contains(where: { elementsAreEqual($0, window) }) else {
            return
        }
        _ = AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
        observation.windows.append(window)
        [
            kAXMovedNotification as String,
            kAXResizedNotification as String,
            kAXWindowMiniaturizedNotification as String,
            kAXWindowDeminiaturizedNotification as String,
            kAXUIElementDestroyedNotification as String
        ].forEach {
            addNotification($0, element: window, observation: observation)
        }
    }

    private func addNotification(
        _ name: String,
        element: AXUIElement,
        observation: ObservedApplication
    ) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let error = AXObserverAddNotification(
            observation.observer,
            element,
            name as CFString,
            refcon
        )
        if error != .success, error != .notificationAlreadyRegistered {
            return
        }
    }

    private func removeAccessibilityObserver(processIdentifier: pid_t) {
        guard let observation = observedApplications.removeValue(
            forKey: processIdentifier
        ) else {
            return
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observation.observer),
            .commonModes
        )
    }

    private func removeAllAccessibilityObservers() {
        Array(observedApplications.keys).forEach {
            removeAccessibilityObserver(processIdentifier: $0)
        }
    }

    private func removeUnusedAccessibilityObservers() {
        let retainedProcessIdentifiers = Set(managedWindows.map(\.processIdentifier))
        for processIdentifier in observedApplications.keys
            where !retainedProcessIdentifiers.contains(processIdentifier) {
            removeAccessibilityObserver(processIdentifier: processIdentifier)
        }
    }

    private func scheduleEvaluation(
        of window: AXUIElement,
        processIdentifier: pid_t
    ) {
        evaluationRevision &+= 1
        let revision = evaluationRevision
        let generation = lifecycleGeneration
        if let existing = pendingEvaluations.first(where: {
            elementsAreEqual($0.element, window)
        }) {
            existing.revision = revision
        } else {
            pendingEvaluations.append(PendingEvaluation(
                element: window,
                processIdentifier: processIdentifier,
                revision: revision
            ))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.evaluationDelay) { [weak self] in
            guard let self,
                  self.isStarted,
                  self.lifecycleGeneration == generation,
                  let request = self.pendingEvaluations.first(where: {
                    self.elementsAreEqual($0.element, window)
                  }),
                  request.revision == revision else {
                return
            }
            self.pendingEvaluations.removeAll {
                self.elementsAreEqual($0.element, window)
            }
            self.evaluate(window: window, processIdentifier: processIdentifier)
        }
    }

    private func evaluate(window: AXUIElement, processIdentifier: pid_t) {
        guard observedApplications[processIdentifier] != nil,
              let currentFrame = accessibilityFrame(of: window) else {
            return
        }

        guard reservationShouldBeActive else {
            evaluateManagedWindowWhileInactive(window, currentFrame: currentFrame)
            return
        }

        if let index = managedWindowIndex(for: window) {
            let managed = managedWindows[index]
            if WindowReservationGeometryPolicy.framesApproximatelyEqual(
                currentFrame,
                managed.reservedFrame
            ) {
                return
            }
            if isLikelyFullScreenFrame(currentFrame) {
                return
            }
            // A user-initiated move or resize takes ownership of the new frame.
            // Do not later restore the stale pre-reservation geometry.
            managedWindows.remove(at: index)
        }

        guard isOrdinaryResizableWindow(window),
              let adjustment = WindowReservationGeometryPolicy.adjustment(
                for: currentFrame,
                displays: displayGeometries
              ),
              let appliedFrame = setAccessibilityFrame(
                adjustment.targetFrame,
                of: window
              ),
              appliedFrame.maxY <= adjustment.targetFrame.maxY
                + WindowReservationGeometryPolicy.defaultFrameTolerance else {
            return
        }

        managedWindows.append(ManagedWindow(
            element: window,
            processIdentifier: processIdentifier,
            originalFrame: currentFrame,
            reservedFrame: appliedFrame,
            displayIdentity: adjustment.displayIdentity
        ))
    }

    private func evaluateManagedWindowWhileInactive(
        _ window: AXUIElement,
        currentFrame: CGRect
    ) {
        guard let index = managedWindowIndex(for: window) else { return }
        let managed = managedWindows[index]
        if WindowReservationGeometryPolicy.framesApproximatelyEqual(
            currentFrame,
            managed.reservedFrame
        ) {
            if restore(managed) {
                managedWindows.remove(at: index)
                removeUnusedAccessibilityObservers()
            }
        } else if !isLikelyFullScreenFrame(currentFrame) {
            // The user changed this window after the feature was disabled.
            managedWindows.remove(at: index)
            removeUnusedAccessibilityObservers()
        }
    }

    private func reconcileManagedWindows() {
        var retained: [ManagedWindow] = []
        for managed in managedWindows {
            guard let currentFrame = accessibilityFrame(of: managed.element) else {
                continue
            }
            guard WindowReservationGeometryPolicy.framesApproximatelyEqual(
                currentFrame,
                managed.reservedFrame
            ) else {
                if isLikelyFullScreenFrame(currentFrame) {
                    retained.append(managed)
                } else {
                    scheduleEvaluation(
                        of: managed.element,
                        processIdentifier: managed.processIdentifier
                    )
                }
                continue
            }

            if let adjustment = WindowReservationGeometryPolicy.adjustment(
                for: managed.originalFrame,
                displays: displayGeometries
            ) {
                if WindowReservationGeometryPolicy.framesApproximatelyEqual(
                    adjustment.targetFrame,
                    managed.reservedFrame
                ) {
                    retained.append(managed)
                    continue
                }
                if let appliedFrame = setAccessibilityFrame(
                    adjustment.targetFrame,
                    of: managed.element
                ) {
                    managed.reservedFrame = appliedFrame
                    managed.displayIdentity = adjustment.displayIdentity
                    retained.append(managed)
                }
            } else if !restore(managed) {
                retained.append(managed)
            }
        }
        managedWindows = retained
    }

    private func restoreManagedWindows() {
        guard permissionService.isGranted else { return }
        var retained: [ManagedWindow] = []
        for managed in managedWindows {
            guard let currentFrame = accessibilityFrame(of: managed.element) else {
                continue
            }
            guard WindowReservationGeometryPolicy.framesApproximatelyEqual(
                currentFrame,
                managed.reservedFrame
            ) else {
                if isLikelyFullScreenFrame(currentFrame) {
                    retained.append(managed)
                }
                continue
            }
            if !restore(managed) {
                retained.append(managed)
            }
        }
        managedWindows = retained
    }

    private func isLikelyFullScreenFrame(_ frame: CGRect) -> Bool {
        topologyProvider.currentDisplays().contains { descriptor in
            !descriptor.isMirrorSecondary
                && WindowReservationGeometryPolicy.framesApproximatelyEqual(
                    frame,
                    CGDisplayBounds(descriptor.displayID)
                )
        }
    }

    private func restore(_ managed: ManagedWindow) -> Bool {
        guard let restoredFrame = setAccessibilityFrame(
            managed.originalFrame,
            of: managed.element
        ) else {
            return false
        }
        return WindowReservationGeometryPolicy.framesApproximatelyEqual(
            restoredFrame,
            managed.originalFrame
        )
    }

    private func removeTrackedWindow(
        _ window: AXUIElement,
        processIdentifier: pid_t
    ) {
        observedApplications[processIdentifier]?.windows.removeAll {
            elementsAreEqual($0, window)
        }
        managedWindows.removeAll { elementsAreEqual($0.element, window) }
        pendingEvaluations.removeAll { elementsAreEqual($0.element, window) }
        mutationSuppressions.removeAll { elementsAreEqual($0.element, window) }
    }

    private func managedWindowIndex(for window: AXUIElement) -> Int? {
        managedWindows.firstIndex { elementsAreEqual($0.element, window) }
    }

    private func consumeSuppressedMutation(
        for window: AXUIElement,
        currentFrame: CGRect
    ) -> Bool {
        let now = Date()
        mutationSuppressions.removeAll { $0.expiration <= now }
        guard let index = mutationSuppressions.firstIndex(where: {
            elementsAreEqual($0.element, window)
        }) else {
            return false
        }
        if WindowReservationGeometryPolicy.framesApproximatelyEqual(
            currentFrame,
            mutationSuppressions[index].expectedFrame
        ) {
            return true
        }
        mutationSuppressions.remove(at: index)
        return false
    }

    private func suppressMutations(
        for window: AXUIElement,
        expectedFrame: CGRect
    ) {
        mutationSuppressions.removeAll { elementsAreEqual($0.element, window) }
        mutationSuppressions.append(MutationSuppression(
            element: window,
            expectedFrame: expectedFrame,
            expiration: Date().addingTimeInterval(Self.mutationSuppressionDuration)
        ))
    }

    private func isOrdinaryResizableWindow(_ window: AXUIElement) -> Bool {
        guard accessibilityString(of: window, attribute: kAXRoleAttribute as String)
                == kAXWindowRole as String,
              accessibilityBool(of: window, attribute: kAXMinimizedAttribute as String) != true,
              accessibilityBool(of: window, attribute: kAXModalAttribute as String) != true,
              isAccessibilityAttributeSettable(
                kAXPositionAttribute as String,
                of: window
              ),
              isAccessibilityAttributeSettable(
                kAXSizeAttribute as String,
                of: window
              ) else {
            return false
        }

        let subrole = accessibilityString(
            of: window,
            attribute: kAXSubroleAttribute as String
        )
        return subrole == nil || subrole == kAXStandardWindowSubrole as String
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

    private func accessibilityFrame(of element: AXUIElement) -> CGRect? {
        guard let position = accessibilityPoint(
            of: element,
            attribute: kAXPositionAttribute as String
        ),
        let size = accessibilitySize(
            of: element,
            attribute: kAXSizeAttribute as String
        ),
        size.width > 0,
        size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func setAccessibilityFrame(
        _ frame: CGRect,
        of element: AXUIElement
    ) -> CGRect? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        suppressMutations(for: element, expectedFrame: frame)

        var point = frame.origin
        var size = frame.size
        guard let pointValue = AXValueCreate(.cgPoint, &point),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return nil
        }

        let currentFrame = accessibilityFrame(of: element)
        if currentFrame.map({ $0.width > frame.width || $0.height > frame.height }) == true {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                sizeValue
            )
            _ = AXUIElementSetAttributeValue(
                element,
                kAXPositionAttribute as CFString,
                pointValue
            )
        } else {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXPositionAttribute as CFString,
                pointValue
            )
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                sizeValue
            )
        }
        // A few apps constrain size relative to their current origin. Reapply
        // position after sizing so the top edge remains anchored.
        _ = AXUIElementSetAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            pointValue
        )

        guard let appliedFrame = accessibilityFrame(of: element) else { return nil }
        suppressMutations(for: element, expectedFrame: appliedFrame)
        return appliedFrame
    }

    private func accessibilityElements(
        of element: AXUIElement,
        attribute: String
    ) -> [AXUIElement] {
        accessibilityValue(of: element, attribute: attribute) as? [AXUIElement] ?? []
    }

    private func accessibilityString(
        of element: AXUIElement,
        attribute: String
    ) -> String? {
        accessibilityValue(of: element, attribute: attribute) as? String
    }

    private func accessibilityBool(
        of element: AXUIElement,
        attribute: String
    ) -> Bool? {
        accessibilityValue(of: element, attribute: attribute) as? Bool
    }

    private func accessibilityPoint(
        of element: AXUIElement,
        attribute: String
    ) -> CGPoint? {
        guard let value = accessibilityValue(of: element, attribute: attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let accessibilityValue = value as! AXValue
        guard AXValueGetType(accessibilityValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(accessibilityValue, .cgPoint, &point) ? point : nil
    }

    private func accessibilitySize(
        of element: AXUIElement,
        attribute: String
    ) -> CGSize? {
        guard let value = accessibilityValue(of: element, attribute: attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let accessibilityValue = value as! AXValue
        guard AXValueGetType(accessibilityValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(accessibilityValue, .cgSize, &size) ? size : nil
    }

    private func accessibilityValue(
        of element: AXUIElement,
        attribute: String
    ) -> CFTypeRef? {
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
        return error == .success ? value : nil
    }

    private func isAccessibilityAttributeSettable(
        _ attribute: String,
        of element: AXUIElement
    ) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &settable
        ) == .success && settable.boolValue
    }

    private func elementsAreEqual(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    private func processIdentifierOfElement(_ element: AXUIElement) -> pid_t? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success else {
            return nil
        }
        return processIdentifier
    }
}

private final class ObservedApplication {
    let processIdentifier: pid_t
    let applicationElement: AXUIElement
    let observer: AXObserver
    var windows: [AXUIElement] = []

    init(
        processIdentifier: pid_t,
        applicationElement: AXUIElement,
        observer: AXObserver
    ) {
        self.processIdentifier = processIdentifier
        self.applicationElement = applicationElement
        self.observer = observer
    }
}

private final class ManagedWindow {
    let element: AXUIElement
    let processIdentifier: pid_t
    let originalFrame: CGRect
    var reservedFrame: CGRect
    var displayIdentity: DisplayIdentity

    init(
        element: AXUIElement,
        processIdentifier: pid_t,
        originalFrame: CGRect,
        reservedFrame: CGRect,
        displayIdentity: DisplayIdentity
    ) {
        self.element = element
        self.processIdentifier = processIdentifier
        self.originalFrame = originalFrame
        self.reservedFrame = reservedFrame
        self.displayIdentity = displayIdentity
    }
}

private final class PendingEvaluation {
    let element: AXUIElement
    let processIdentifier: pid_t
    var revision: UInt64

    init(element: AXUIElement, processIdentifier: pid_t, revision: UInt64) {
        self.element = element
        self.processIdentifier = processIdentifier
        self.revision = revision
    }
}

private struct MutationSuppression {
    let element: AXUIElement
    let expectedFrame: CGRect
    let expiration: Date
}
