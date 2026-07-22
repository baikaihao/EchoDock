import AppKit

@MainActor
final class NativeDockPolicyController {
    private let preferences: PreferencesStore
    private let topologyProvider: DisplayTopologyProvider
    private let nativeDockLockService: NativeDockLockService
    private var notificationObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var isStarted = false

    init(
        preferences: PreferencesStore,
        topologyProvider: DisplayTopologyProvider = DisplayTopologyProvider(),
        nativeDockLockService: NativeDockLockService = NativeDockLockService()
    ) {
        self.preferences = preferences
        self.topologyProvider = topologyProvider
        self.nativeDockLockService = nativeDockLockService
        self.nativeDockLockService.onStatusChange = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.synchronizeSetupState()
            }
        }
    }

    var nativeDockLockStatus: NativeDockLockStatus {
        nativeDockLockService.status
    }

    var currentNativeDockDisplayID: CGDirectDisplayID? {
        nativeDockLockService.currentDockDisplayID
    }

    func start() {
        guard notificationObservers.isEmpty else { return }

        isStarted = true
        nativeDockLockService.start()

        let defaultCenter = NotificationCenter.default
        let preferencesToken = defaultCenter.addObserver(
            forName: .echoDockPreferencesDidChange,
            object: preferences,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        notificationObservers.append((defaultCenter, preferencesToken))

        let screenParametersToken = defaultCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        notificationObservers.append((defaultCenter, screenParametersToken))

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let sessionToken = workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        notificationObservers.append((workspaceCenter, sessionToken))

        reconcile()
    }

    func stop() {
        isStarted = false
        nativeDockLockService.stop()
        for observer in notificationObservers {
            observer.center.removeObserver(observer.token)
        }
        notificationObservers.removeAll()
    }

    func reconcile() {
        let displays = topologyProvider.currentDisplays()
        nativeDockLockService.refreshCurrentDockDisplay(displays: displays)

        let targetIdentity = preferences.nativeDockTarget
        let target = targetIdentity.flatMap { identity in
            displays.first(where: { $0.identity == identity })
        }
        let screensHaveSeparateSpaces = NSScreen.screensHaveSeparateSpaces
        let targetIsEligible = target.map { !$0.isMirrorSecondary } ?? false
        let canProtectTarget = preferences.nativeDockStrategy == .fixedToSelectedDisplay
            && targetIsEligible
            && (target?.isMain == true || screensHaveSeparateSpaces)

        nativeDockLockService.configure(
            enabled: canProtectTarget,
            targetDisplayID: target?.displayID,
            displays: displays
        )

        let state = NativeDockPolicyStateMachine.evaluate(
            strategy: preferences.nativeDockStrategy,
            hasTarget: targetIdentity != nil,
            targetIsAvailable: target != nil,
            targetIsEligible: targetIsEligible,
            targetIsMain: target?.isMain ?? false,
            screensHaveSeparateSpaces: screensHaveSeparateSpaces,
            lockStatus: nativeDockLockService.status
        )
        setStateIfNeeded(state)
    }

    private func synchronizeSetupState() {
        let displays = topologyProvider.currentDisplays()
        let targetIdentity = preferences.nativeDockTarget
        let target = targetIdentity.flatMap { identity in
            displays.first(where: { $0.identity == identity })
        }
        let state = NativeDockPolicyStateMachine.evaluate(
            strategy: preferences.nativeDockStrategy,
            hasTarget: targetIdentity != nil,
            targetIsAvailable: target != nil,
            targetIsEligible: target.map { !$0.isMirrorSecondary } ?? false,
            targetIsMain: target?.isMain ?? false,
            screensHaveSeparateSpaces: NSScreen.screensHaveSeparateSpaces,
            lockStatus: nativeDockLockService.status
        )
        setStateIfNeeded(state)
    }

    private func setStateIfNeeded(_ state: NativeDockSetupState) {
        guard preferences.nativeDockSetupState != state else { return }
        preferences.nativeDockSetupState = state
    }
}
