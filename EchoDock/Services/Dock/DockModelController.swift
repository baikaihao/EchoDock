import AppKit
import Carbon

@MainActor
protocol WorkspaceApplicationOpening: AnyObject {
    func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completionHandler: (@Sendable (NSRunningApplication?, Error?) -> Void)?
    )
}

extension NSWorkspace: WorkspaceApplicationOpening {}

@MainActor
protocol RunningApplicationOperating {
    func isActive(_ application: NSRunningApplication) -> Bool
    func isHidden(_ application: NSRunningApplication) -> Bool
    func isTerminated(_ application: NSRunningApplication) -> Bool
    func unhide(_ application: NSRunningApplication) -> Bool
    func hide(_ application: NSRunningApplication) -> Bool
    func terminate(_ application: NSRunningApplication) -> Bool
    func activate(
        _ application: NSRunningApplication,
        options: NSApplication.ActivationOptions
    ) -> Bool
}

@MainActor
struct SystemRunningApplicationOperations: RunningApplicationOperating {
    func isActive(_ application: NSRunningApplication) -> Bool {
        application.isActive
    }

    func isHidden(_ application: NSRunningApplication) -> Bool {
        application.isHidden
    }

    func isTerminated(_ application: NSRunningApplication) -> Bool {
        application.isTerminated
    }

    func unhide(_ application: NSRunningApplication) -> Bool {
        application.unhide()
    }

    func hide(_ application: NSRunningApplication) -> Bool {
        application.hide()
    }

    func terminate(_ application: NSRunningApplication) -> Bool {
        application.terminate()
    }

    func activate(
        _ application: NSRunningApplication,
        options: NSApplication.ActivationOptions
    ) -> Bool {
        application.activate(options: options)
    }
}

@MainActor
final class RunningApplicationActivationService {
    private let workspace: WorkspaceApplicationOpening
    private let operations: RunningApplicationOperating
    private let visibleWindowProcessIdentifiers: () -> Set<pid_t>
    private var nextPresentationGeneration: UInt64 = 0
    private var foregroundGeneration: UInt64 = 0
    private var presentationRequests: [pid_t: (
        generation: UInt64, hidden: Bool, onStaleReopen: (() -> Void)?
    )] = [:]

    init(
        workspace: WorkspaceApplicationOpening,
        operations: RunningApplicationOperating? = nil,
        visibleWindowProcessIdentifiers: (() -> Set<pid_t>)? = nil
    ) {
        self.workspace = workspace
        self.operations = operations ?? SystemRunningApplicationOperations()
        self.visibleWindowProcessIdentifiers = visibleWindowProcessIdentifiers
            ?? VisibleApplicationWindows.processIdentifiers
    }

    func hasActiveVisibleApplication(_ applications: [NSRunningApplication]) -> Bool {
        let activeApplications = applications.filter {
            !operations.isTerminated($0) && operations.isActive($0) && !operations.isHidden($0)
        }
        guard !activeApplications.isEmpty else { return false }
        let visibleProcesses = visibleWindowProcessIdentifiers()
        return activeApplications.contains { visibleProcesses.contains($0.processIdentifier) }
    }

    func reopen(
        _ application: NSRunningApplication,
        applicationURL: URL,
        completion: @escaping (Error?) -> Void
    ) {
        let foregroundGeneration = invalidatePendingForegroundRequests()
        let generation = recordPresentationRequest(application, hidden: false)
        let activatedBeforeReopen = prepareForForeground(application)
        let configuration = Self.reopenConfiguration(for: application)

        workspace.openApplication(at: applicationURL, configuration: configuration) { [weak self] reopenedApplication, error in
            DispatchQueue.main.async {
                guard let self else { return }

                // 新的点击意图优先。系统打开请求不能取消；若它晚于隐藏
                // 操作完成，再次隐藏，避免旧回调将窗口重新拉到前台。
                let request = self.presentationRequests[application.processIdentifier]
                guard request?.generation == generation else {
                    let staleApplication = reopenedApplication ?? application
                    if let reapply = request?.onStaleReopen {
                        reapply()
                    } else if request?.hidden == true && !self.operations.isTerminated(staleApplication) {
                        _ = self.operations.hide(staleApplication)
                    }
                    completion(nil)
                    return
                }

                // A more recent action for another application also wins.
                // Per-process generations alone cannot prevent focus stealing
                // when the user clicks A and then B before A finishes opening.
                guard self.foregroundGeneration == foregroundGeneration else {
                    completion(nil)
                    return
                }

                if let reopenedApplication {
                    _ = self.prepareForForeground(reopenedApplication)
                }

                guard let error else {
                    completion(nil)
                    return
                }

                let fallbackApplication = reopenedApplication ?? application
                let activatedAfterFailure: Bool
                if !self.operations.isTerminated(fallbackApplication) {
                    activatedAfterFailure = self.prepareForForeground(fallbackApplication)
                } else {
                    activatedAfterFailure = false
                }

                completion(activatedBeforeReopen || activatedAfterFailure ? nil : error)
            }
        }
        scheduleForegroundVerification(application, generation: generation, foregroundGeneration: foregroundGeneration)
    }

    func hide(_ applications: [NSRunningApplication]) -> Bool {
        guard !applications.isEmpty else { return false }
        invalidatePendingForegroundRequests()
        applications.forEach { _ = recordPresentationRequest($0, hidden: true) }
        let requestsSucceeded = perform(applications, operation: operations.hide)
        return requestsSucceeded || areHiddenOrTerminated(applications)
    }

    func areHiddenOrTerminated(_ applications: [NSRunningApplication]) -> Bool {
        applications.allSatisfy { application in
            operations.isTerminated(application) || operations.isHidden(application)
        }
    }

    func activateAllWindows(_ applications: [NSRunningApplication]) -> Bool {
        let foregroundGeneration = invalidatePendingForegroundRequests()
        let generations = applications.map { recordPresentationRequest($0, hidden: false) }
        let result = perform(applications, operation: prepareForForeground)
        // 多实例时只确认最后一个（首选实例）的焦点，避免实例互相抢前台。
        if let application = applications.last, let generation = generations.last {
            scheduleForegroundVerification(application, generation: generation, foregroundGeneration: foregroundGeneration)
        }
        return result
    }

    func cancelPendingReopen(
        _ applications: [NSRunningApplication],
        onStaleReopen: @escaping () -> Void
    ) {
        invalidatePendingForegroundRequests()
        applications.forEach {
            _ = recordPresentationRequest($0, hidden: false, onStaleReopen: onStaleReopen)
        }
    }

    func terminate(_ applications: [NSRunningApplication]) -> Bool {
        invalidatePendingForegroundRequests()
        // Quitting may leave a save-confirmation dialog open. Cancel stale
        // activation without hiding that dialog if the process is still alive.
        applications.forEach { _ = recordPresentationRequest($0, hidden: false) }
        return perform(applications, operation: operations.terminate)
    }

    @discardableResult
    func invalidatePendingForegroundRequests() -> UInt64 {
        foregroundGeneration &+= 1
        return foregroundGeneration
    }

    private func recordPresentationRequest(
        _ application: NSRunningApplication,
        hidden: Bool,
        onStaleReopen: (() -> Void)? = nil
    ) -> UInt64 {
        nextPresentationGeneration &+= 1
        presentationRequests[application.processIdentifier] = (nextPresentationGeneration, hidden, onStaleReopen)
        return nextPresentationGeneration
    }

    private func scheduleForegroundVerification(
        _ application: NSRunningApplication,
        generation: UInt64,
        foregroundGeneration: UInt64,
        delays: [TimeInterval] = [0.05, 0.10, 0.20]
    ) {
        guard let delay = delays.first else { return }
        // AppKit 的取消隐藏和激活均为异步请求。只在本次点击仍有效时
        // 进行短暂、有上限的确认，绝不重发可能新建窗口的 reopen 事件。
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.foregroundGeneration == foregroundGeneration,
                  let request = self.presentationRequests[application.processIdentifier],
                  request.generation == generation, !request.hidden,
                  request.onStaleReopen == nil,
                  !self.operations.isTerminated(application) else { return }
            if self.operations.isActive(application) && !self.operations.isHidden(application) { return }
            if self.operations.isHidden(application) {
                _ = self.operations.unhide(application)
            } else {
                _ = self.operations.activate(application, options: Self.activationOptions)
            }
            self.scheduleForegroundVerification(
                application, generation: generation, foregroundGeneration: foregroundGeneration,
                delays: Array(delays.dropFirst())
            )
        }
    }

    static func reopenConfiguration(
        for application: NSRunningApplication
    ) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        // Foregrounding is handled explicitly above and checked against the
        // latest intent. A late Launch Services request must not independently
        // steal focus after the user has selected another application.
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.appleEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor(
                processIdentifier: application.processIdentifier
            ),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        return configuration
    }

    static func launchConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        return configuration
    }

    private func prepareForForeground(_ application: NSRunningApplication) -> Bool {
        guard !operations.isTerminated(application) else { return false }
        if operations.isHidden(application) {
            _ = operations.unhide(application)
        }
        return operations.activate(application, options: Self.activationOptions)
    }

    private func perform(
        _ applications: [NSRunningApplication],
        operation: (NSRunningApplication) -> Bool
    ) -> Bool {
        var attempted = false
        var allSucceeded = true
        for application in applications where !operations.isTerminated(application) {
            attempted = true
            if !operation(application) {
                allSucceeded = false
            }
        }
        return attempted && allSucceeded
    }

    private static var activationOptions: NSApplication.ActivationOptions {
        var options: NSApplication.ActivationOptions = [.activateAllWindows]
        if #unavailable(macOS 14.0) {
            options.insert(.activateIgnoringOtherApps)
        }
        return options
    }
}

enum VisibleApplicationWindows {
    static func processIdentifiers() -> Set<pid_t> {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return processIdentifiers(in: windows)
    }

    static func processIdentifiers(in windows: [[String: Any]]) -> Set<pid_t> {
        Set(windows.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  !frame.isEmpty else { return nil }
            return pid_t(pid)
        })
    }
}

struct LaunchAttemptGenerationGate {
    private var nextGeneration: UInt64 = 0
    private var activeGenerations: [ApplicationIdentity: UInt64] = [:]

    mutating func begin(for identity: ApplicationIdentity) -> UInt64 {
        nextGeneration &+= 1
        activeGenerations[identity] = nextGeneration
        return nextGeneration
    }

    func isCurrent(_ generation: UInt64, for identity: ApplicationIdentity) -> Bool {
        activeGenerations[identity] == generation
    }

    func activeGeneration(for identity: ApplicationIdentity) -> UInt64? {
        activeGenerations[identity]
    }

    @discardableResult
    mutating func invalidate(_ generation: UInt64, for identity: ApplicationIdentity) -> Bool {
        guard activeGenerations[identity] == generation else { return false }
        activeGenerations.removeValue(forKey: identity)
        return true
    }

    mutating func invalidateAll() {
        activeGenerations.removeAll()
    }
}

enum RunningApplicationURLDisambiguator {
    static func preferredIndices(
        candidateURLs: [URL?],
        targetURL: URL
    ) -> [Int] {
        let candidatePaths = candidateURLs.compactMap { $0.map(canonicalPath) }
        guard Set(candidatePaths).count > 1 else {
            return Array(candidateURLs.indices)
        }

        let targetPath = canonicalPath(targetURL)
        let exactMatches = candidateURLs.indices.filter { index in
            candidateURLs[index].flatMap(canonicalPath) == targetPath
        }
        return exactMatches.isEmpty ? Array(candidateURLs.indices) : exactMatches
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

@MainActor
final class DockModelController {
    static let launchTimeout: TimeInterval = 30
    static let systemLaunchBounceTimeout: TimeInterval = 30
    static let failureDisplayDuration: TimeInterval = 5
    static let hideVerificationDelay: TimeInterval = 0.15
    static let metadataRefreshInterval: TimeInterval = 30
    static let failedResolutionRetryInterval: TimeInterval = 5

    var onSnapshotChange: ((DockSnapshot) -> Void)?
    var onFileUndoFailure: ((String) -> Void)?

    var canUndoFileOperation: Bool { trashUndoService.canUndo }

    private let preferencesReader: DockPreferencesReading
    private let metadataResolver: ApplicationMetadataResolving
    private let preferenceMonitor: DockPreferenceMonitor
    private let runningMonitor: RunningApplicationMonitoring
    private let cache: PinnedApplicationCaching
    private let preferences: PreferencesStore
    private let workspace: NSWorkspace
    private let activationService: RunningApplicationActivationService
    private let applicationWindowService: ApplicationWindowControlling
    private let runningApplicationsProvider: () -> [NSRunningApplication]
    private let isControllableRunningApplication: (NSRunningApplication) -> Bool
    private let fileShortcutStore: DockFileShortcutStore
    private let fileOperator: DockFileOperator
    private let trashUndoService: TrashUndoService
    private let currentTime: () -> TimeInterval

    private var pinnedApplications: [PinnedApplication] = []
    private var hasValidPinnedApplications = false
    private var lastReadEntries: [DockPreferenceEntry]?
    private var metadataByKey: [DockApplicationMetadataKey: PinnedApplication] = [:]
    private var metadataRefreshTime: TimeInterval?
    private var resolutionAttemptTime: TimeInterval?
    private var lastResolutionSucceeded = false
    private var cachedFinder: PinnedApplication?
    private var hasResolvedFinder = false
    private var syncStatus: DockSyncStatus = .unavailable(L10n.text("dock.sync.notSynced"))
    private var transientStateByIdentity: [ApplicationIdentity: DockItemTransientState] = [:]
    private var launchGenerationGate = LaunchAttemptGenerationGate()
    private var launchTimeoutWorkItems: [ApplicationIdentity: DispatchWorkItem] = [:]
    private var hideVerificationWorkItems: [ApplicationIdentity: DispatchWorkItem] = [:]
    private var hideVerificationGeneration: UInt64 = 0
    private var hideVerificationGenerations: [ApplicationIdentity: UInt64] = [:]
    private var failureDismissalWorkItems: [ApplicationIdentity: DispatchWorkItem] = [:]
    private var failureDismissalGeneration: UInt64 = 0
    private var failureDismissalGenerations: [ApplicationIdentity: UInt64] = [:]
    private var systemLaunchPulseGeneration: UInt64 = 0
    private var systemLaunchPulseGenerations: [ApplicationIdentity: UInt64] = [:]
    private var systemLaunchTimeoutWorkItems: [ApplicationIdentity: DispatchWorkItem] = [:]
    private var launchCompletionGenerations: [ApplicationIdentity: UInt64] = [:]
    private var revision: UInt64 = 0
    private var preferencesObserver: NSObjectProtocol?
    private var windowActionGeneration: UInt64 = 0
    private var windowActionFrontmostPID: pid_t?
    private(set) var snapshot: DockSnapshot = .empty

    init(
        preferencesReader: DockPreferencesReading = DockPreferencesReader(),
        metadataResolver: ApplicationMetadataResolving = ApplicationMetadataResolver(),
        preferenceMonitor: DockPreferenceMonitor? = nil,
        runningMonitor: RunningApplicationMonitoring? = nil,
        cache: PinnedApplicationCaching = PinnedApplicationCache(),
        preferences: PreferencesStore,
        workspace: NSWorkspace = .shared,
        activationService: RunningApplicationActivationService? = nil,
        applicationWindowService: ApplicationWindowControlling? = nil,
        runningApplicationsProvider: (() -> [NSRunningApplication])? = nil,
        isControllableRunningApplication: ((NSRunningApplication) -> Bool)? = nil,
        fileShortcutStore: DockFileShortcutStore? = nil,
        fileOperator: DockFileOperator? = nil,
        trashUndoService: TrashUndoService? = nil,
        currentTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.preferencesReader = preferencesReader
        self.metadataResolver = metadataResolver
        self.preferenceMonitor = preferenceMonitor ?? DockPreferenceMonitor()
        self.runningMonitor = runningMonitor ?? RunningApplicationMonitor()
        self.cache = cache
        self.preferences = preferences
        self.workspace = workspace
        self.activationService = activationService
            ?? RunningApplicationActivationService(workspace: workspace)
        self.applicationWindowService = applicationWindowService
            ?? BackgroundApplicationWindowService.system()
        self.runningApplicationsProvider = runningApplicationsProvider
            ?? { workspace.runningApplications }
        self.isControllableRunningApplication = isControllableRunningApplication
            ?? { $0.activationPolicy == .regular }
        let shortcutStore = fileShortcutStore ?? DockFileShortcutStore()
        self.fileShortcutStore = shortcutStore
        self.fileOperator = fileOperator ?? DockFileOperator(workspace: workspace)
        self.trashUndoService = trashUndoService
            ?? TrashUndoService(shortcutStore: shortcutStore)
        self.currentTime = currentTime
    }

    func start() {
        if let cached = cache.load() {
            pinnedApplications = cached
            hasValidPinnedApplications = true
            syncStatus = .cached
            publishIfNeeded()
        }

        preferenceMonitor.onPossibleChange = { [weak self] in
            self?.refreshDockItems()
        }
        preferenceMonitor.onMetadataInvalidation = { [weak self] in self?.refresh() }
        runningMonitor.onChange = { [weak self] in
            self?.handleRunningApplicationChange()
        }
        runningMonitor.onApplicationWillLaunch = { [weak self] identity in
            self?.handleSystemApplicationWillLaunch(identity)
        }
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: .echoDockPreferencesDidChange,
            object: preferences,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publishIfNeeded() }
        }

        runningMonitor.start()
        preferenceMonitor.start()
        refreshDockItems()
    }

    func stop() {
        invalidateWindowActions()
        launchTimeoutWorkItems.values.forEach { $0.cancel() }
        launchTimeoutWorkItems.removeAll()
        systemLaunchTimeoutWorkItems.values.forEach { $0.cancel() }
        systemLaunchTimeoutWorkItems.removeAll()
        launchCompletionGenerations.removeAll()
        hideVerificationWorkItems.values.forEach { $0.cancel() }
        hideVerificationWorkItems.removeAll()
        hideVerificationGenerations.removeAll()
        failureDismissalWorkItems.values.forEach { $0.cancel() }
        failureDismissalWorkItems.removeAll()
        failureDismissalGenerations.removeAll()
        systemLaunchPulseGenerations.removeAll()
        transientStateByIdentity.removeAll()
        launchGenerationGate.invalidateAll()
        trashUndoService.removeAllTransactions()
        preferenceMonitor.stop()
        preferenceMonitor.onPossibleChange = nil
        preferenceMonitor.onMetadataInvalidation = nil
        lastReadEntries = nil
        metadataByKey.removeAll()
        metadataRefreshTime = nil
        cachedFinder = nil
        hasResolvedFinder = false
        runningMonitor.onChange = nil
        runningMonitor.onApplicationWillLaunch = nil
        runningMonitor.stop()
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
        preferencesObserver = nil
    }

    func refresh() {
        fileShortcutStore.invalidateResolvedShortcuts()
        runningMonitor.reconcile()
        refreshDockItems(forceMetadataRefresh: true)
    }

    func undoLastFileOperation() {
        let result = trashUndoService.undoLatestTransaction()
        publishIfNeeded()
        guard !result.failures.isEmpty else { return }
        var messages = result.failures.prefix(5).map(\.message)
        if result.failures.count > 5 {
            messages.append(L10n.format("fileUndo.error.more", result.failures.count - 5))
        }
        onFileUndoFailure?(messages.joined(separator: "\n"))
    }

    func performPrimaryAction(for item: DockItem) {
        let generation = invalidateWindowActions()
        activationService.invalidatePendingForegroundRequests()
        switch item.kind {
        case .fileShortcut(_, _, let isAvailable):
            if isAvailable {
                _ = workspace.open(item.applicationURL)
            } else {
                NSSound.beep()
            }
            return
        case .trash:
            _ = workspace.open(item.applicationURL)
            return
        case .dropPlaceholder:
            return
        case .application:
            break
        }
        cancelHideVerification(for: item.identity)
        let applications = currentRunningApplications(for: item)
        if applications.isEmpty {
            launchApplication(item)
        } else {
            let processIdentifiers = applications.sorted(by: preferredApplication).map(\.processIdentifier)
            let shouldMinimize = activationService.hasActiveVisibleApplication(applications)
            applicationWindowService.restoreLastMinimizedWindow(processIdentifiers: processIdentifiers) { [weak self] result in
                guard let self, self.isWindowActionCurrent(generation, targetProcessIdentifiers: processIdentifiers) else { return }
                self.finishPrimaryWindowAction(result, item: item, applications: applications,
                                               processIdentifiers: processIdentifiers, shouldMinimize: shouldMinimize, generation: generation)
            }
        }
    }

    private func finishPrimaryWindowAction(
        _ result: ApplicationWindowRestoreResult,
        item: DockItem,
        applications: [NSRunningApplication],
        processIdentifiers: [pid_t],
        shouldMinimize: Bool,
        generation: UInt64
    ) {
        switch result {
        case let .restored(processIdentifier):
            // Only foreground the instance whose remembered window was
            // restored; another instance may currently be preferred.
            let restoredApplications = applications.filter { $0.processIdentifier == processIdentifier }
            _ = activationService.activateAllWindows(restoredApplications)
            runningMonitor.reconcile()
            return
        case .failed:
            showTemporaryFailure(L10n.text("dock.error.restoreWindow"), identity: item.identity)
            return
        case .none, .permissionDenied:
            break
        }

        // 使用实时前台状态，避免图标快照滞后；无可见窗口时仍应恢复。
        if shouldMinimize {
            applicationWindowService.minimizePreferredWindow(processIdentifiers: processIdentifiers) { [weak self] result in
                guard let self, self.windowActionGeneration == generation else { return }
                self.finishMinimization(result, item: item, applications: applications,
                                        processIdentifiers: processIdentifiers, generation: generation)
            }
        } else {
            if activationService.hasActiveVisibleApplication(applications) { return }
            activateRunningApplication(item, candidates: applications)
        }
    }

    private func finishMinimization(
        _ result: ApplicationWindowMinimizeResult,
        item: DockItem,
        applications: [NSRunningApplication],
        processIdentifiers: [pid_t],
        generation: UInt64
    ) {
        switch result {
        case .requested:
            activationService.cancelPendingReopen(applications) { [weak self] in
                // 若更早的打开请求晚到，只重新最小化同一个已记住的窗口。
                guard let self, self.windowActionGeneration == generation else { return }
                self.applicationWindowService.reapplyLastMinimization(processIdentifiers: processIdentifiers) { _ in }
            }
            clearTemporaryFailure(for: item.identity)
            runningMonitor.reconcile()
        case .permissionDenied:
            showTemporaryFailure(L10n.text("dock.error.accessibilityMinimize"), identity: item.identity)
        case .noMinimizableWindow, .failed:
            showTemporaryFailure(L10n.text("dock.error.minimizeWindow"), identity: item.identity)
        }
    }

    @discardableResult
    private func invalidateWindowActions() -> UInt64 {
        windowActionGeneration &+= 1
        windowActionFrontmostPID = workspace.frontmostApplication?.processIdentifier
        applicationWindowService.invalidatePendingOperations()
        return windowActionGeneration
    }

    private func isWindowActionCurrent(_ generation: UInt64, targetProcessIdentifiers: [pid_t]) -> Bool {
        guard windowActionGeneration == generation else { return false }
        let current = workspace.frontmostApplication?.processIdentifier
        return current == windowActionFrontmostPID || current.map(targetProcessIdentifiers.contains) == true
    }

    func handleSystemApplicationWillLaunch(_ identity: ApplicationIdentity) {
        guard Self.shouldAnimateSystemLaunch(for: identity, in: snapshot) else { return }

        systemLaunchPulseGeneration &+= 1
        let generation = systemLaunchPulseGeneration
        systemLaunchPulseGenerations[identity] = generation
        transientStateByIdentity[identity] = .launching
        publishIfNeeded()

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.systemLaunchPulseGenerations[identity] == generation else { return }
            self.systemLaunchPulseGenerations.removeValue(forKey: identity)
            self.systemLaunchTimeoutWorkItems.removeValue(forKey: identity)
            guard self.transientStateByIdentity[identity] == .launching else { return }
            self.transientStateByIdentity.removeValue(forKey: identity)
            self.publishIfNeeded()
        }
        systemLaunchTimeoutWorkItems[identity]?.cancel()
        systemLaunchTimeoutWorkItems[identity] = timeoutWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.systemLaunchBounceTimeout,
            execute: timeoutWorkItem
        )
    }

    static func shouldAnimateSystemLaunch(
        for identity: ApplicationIdentity,
        in snapshot: DockSnapshot
    ) -> Bool {
        guard let item = snapshot.items.prefix(snapshot.pinnedItemCount).first(where: {
            $0.identity == identity && $0.section == .pinned
        }) else {
            return false
        }
        return !item.isRunning && item.transientState != .launching
    }

    func contextMenuState(for item: DockItem) -> DockItemContextMenuState {
        guard item.kind.isApplication, item.isRunning else { return .unavailable }
        let processIdentifiers = preferredProcessIdentifiers(for: item)
        let hasPermission = applicationWindowService.hasAccessibilityPermission
        return DockItemContextMenuState(
            canCloseWindow: hasPermission
                && applicationWindowService.canCloseWindow(
                    processIdentifiers: processIdentifiers
                ),
            requiresAccessibilityPermission: !processIdentifiers.isEmpty && !hasPermission
        )
    }

    func performContextAction(_ action: DockItemContextAction, for item: DockItem) {
        let generation = invalidateWindowActions()
        activationService.invalidatePendingForegroundRequests()
        cancelHideVerification(for: item.identity)
        switch action {
        case .revealInFinder:
            workspace.activateFileViewerSelecting([item.applicationURL])

        case .open:
            guard item.kind.isApplication else {
                _ = workspace.open(item.applicationURL)
                return
            }
            let applications = currentRunningApplications(for: item)
            if applications.isEmpty {
                launchApplication(item)
            } else {
                activateRunningApplication(item, candidates: applications)
            }

        case .showAllWindows, .show:
            let applications = currentRunningApplications(for: item)
            guard !applications.isEmpty else {
                runningMonitor.reconcile()
                return
            }
            // Context-menu display commands must not send a reopen Apple
            // event: applications can interpret it as a request for a new
            // window. Activate every instance instead, leaving the preferred
            // instance last so it remains frontmost.
            let leastPreferredFirst = applications.sorted(by: preferredApplication).reversed()
            if !activationService.activateAllWindows(Array(leastPreferredFirst)) {
                showTemporaryFailure(
                    L10n.format("dock.error.unableShow", item.displayName),
                    identity: item.identity
                )
            }
            runningMonitor.reconcile()

        case .closeWindow:
            let processIdentifiers = preferredProcessIdentifiers(for: item)
            guard !processIdentifiers.isEmpty else {
                runningMonitor.reconcile()
                return
            }
            applicationWindowService.closePreferredWindow(processIdentifiers: processIdentifiers) { [weak self] result in
                guard let self, self.windowActionGeneration == generation else { return }
                switch result {
            case .requested, .noClosableWindow:
                break
            case .permissionDenied:
                self.showTemporaryFailure(
                    L10n.text("dock.error.accessibilityClose"),
                    identity: item.identity
                )
            case .failed:
                self.showTemporaryFailure(
                    L10n.format("dock.error.unableClose", item.displayName),
                    identity: item.identity
                )
                }
            }

        case .hide:
            let applications = currentRunningApplications(for: item)
            guard !applications.isEmpty else {
                runningMonitor.reconcile()
                return
            }
            _ = activationService.hide(applications)
            runningMonitor.reconcile()
            if activationService.areHiddenOrTerminated(applications) {
                clearTemporaryFailure(for: item.identity)
            } else {
                scheduleHideVerification(
                    for: item,
                    applications: applications
                )
            }

        case .quit:
            guard !DockItemContextMenuBuilder.isFinder(item) else { return }
            let applications = currentRunningApplications(for: item)
            guard !applications.isEmpty else {
                runningMonitor.reconcile()
                return
            }
            if !activationService.terminate(applications) {
                showTemporaryFailure(
                    L10n.format("dock.error.unableQuit", item.displayName),
                    identity: item.identity
                )
            }
            runningMonitor.reconcile()

        case .removeShortcut:
            guard let shortcutID = item.kind.shortcutID else { return }
            let snapshots = fileShortcutStore.snapshots(for: [shortcutID])
            if fileShortcutStore.remove(shortcutIDs: [shortcutID]) {
                trashUndoService.recordShortcutRemoval(snapshots)
                publishIfNeeded()
            }
        }
    }

    @discardableResult
    func handleDrop(_ request: DockDropRequest) -> Bool {
        switch request.destination {
        case let .shortcuts(index):
            let changed: Bool
            if request.sourceShortcutIDs.isEmpty {
                changed = fileShortcutStore.insert(
                    fileURLs: request.fileURLs,
                    at: index
                )
            } else {
                changed = fileShortcutStore.move(
                    shortcutIDs: request.sourceShortcutIDs,
                    to: index
                )
            }
            if changed { publishIfNeeded() }
            return changed

        case .trash:
            if !request.sourceShortcutIDs.isEmpty {
                let snapshots = fileShortcutStore.snapshots(
                    for: request.sourceShortcutIDs
                )
                let changed = fileShortcutStore.remove(
                    shortcutIDs: request.sourceShortcutIDs
                )
                if changed {
                    trashUndoService.recordShortcutRemoval(snapshots)
                    publishIfNeeded()
                }
                return changed
            }

            guard !request.fileURLs.isEmpty else { return false }
            recycleDroppedFiles(request)
            return true
        }
    }

    private func refreshDockItems(forceMetadataRefresh: Bool = false) {
        do {
            let entries = try preferencesReader.readEntries()
            let now = currentTime()
            // Periodic expiry also catches changes to app bundles without a
            // matching Dock preference notification. Manual refresh bypasses it.
            let refreshMetadata = forceMetadataRefresh
                || (metadataRefreshTime.map { now - $0 >= Self.metadataRefreshInterval } ?? true)
            if refreshMetadata {
                metadataByKey.removeAll()
                cachedFinder = nil
                hasResolvedFinder = false
                metadataRefreshTime = now
            }
            let retryFailedResolution = !lastResolutionSucceeded
                && (resolutionAttemptTime.map { now - $0 >= Self.failedResolutionRetryInterval } ?? true)
            if entries == lastReadEntries, !refreshMetadata, !retryFailedResolution {
                if lastResolutionSucceeded { syncStatus = .normal }
                publishIfNeeded()
                return
            }
            lastReadEntries = entries
            resolutionAttemptTime = now

            let currentKeys = Set(entries.map(DockApplicationMetadataKey.init))
            metadataByKey = metadataByKey.filter { currentKeys.contains($0.key) }

            var seenApplications = Set<ApplicationIdentity>()
            let resolvedApplicationEntries = entries.compactMap { entry -> PinnedApplication? in
                let key = DockApplicationMetadataKey(entry)
                guard let application = metadataByKey[key] ?? metadataResolver.resolve(entry) else { return nil }
                metadataByKey[key] = application
                return PinnedApplication(
                    identity: application.identity,
                    bundleIdentifier: application.bundleIdentifier,
                    applicationURL: application.applicationURL,
                    displayName: application.displayName,
                    sourceOrder: entry.sourceOrder
                )
            }
            let resolvedApplications = resolvedApplicationEntries
                .sorted { $0.sourceOrder < $1.sourceOrder }
                .filter { application in
                    application.bundleIdentifier?.lowercased() != "com.apple.finder"
                        && seenApplications.insert(application.identity).inserted
                }

            if Self.resolutionFailed(
                entryCount: entries.count,
                resolvedCount: resolvedApplicationEntries.count
            ) {
                lastResolutionSucceeded = false
                syncStatus = cachedApplicationsStatus(L10n.text("dock.error.parsePinnedApps"))
            } else {
                lastResolutionSucceeded = true
                if !hasValidPinnedApplications || pinnedApplications != resolvedApplications {
                    cache.save(resolvedApplications)
                }
                pinnedApplications = resolvedApplications
                hasValidPinnedApplications = true
                syncStatus = .normal
            }
        } catch {
            syncStatus = cachedApplicationsStatus(error.localizedDescription)
        }
        publishIfNeeded()
    }

    static func resolutionFailed(entryCount: Int, resolvedCount: Int) -> Bool {
        entryCount > 0 && resolvedCount == 0
    }

    private func cachedApplicationsStatus(_ message: String) -> DockSyncStatus {
        if hasValidPinnedApplications { return .cached }
        if let cached = cache.load() {
            pinnedApplications = cached
            hasValidPinnedApplications = true
            return .cached
        } else {
            return .unavailable(message)
        }
    }

    private func publishIfNeeded() {
        if !hasResolvedFinder {
            cachedFinder = metadataResolver.finderApplication()
            hasResolvedFinder = true
        }
        let buildResult = DockSnapshotBuilder.build(
            finder: cachedFinder,
            pinnedApplications: pinnedApplications,
            runningApplications: runningMonitor.records,
            showRunningApplications: preferences.showRunningApplications,
            transientStates: transientStateByIdentity,
            fileShortcuts: fileShortcutStore.resolvedShortcuts
        )
        let items = buildResult.items
        let pinnedItemCount = buildResult.pinnedItemCount

        let candidate = DockSnapshot(
            revision: revision,
            items: items,
            pinnedItemCount: pinnedItemCount,
            syncStatus: syncStatus
        )

        guard candidate.items != snapshot.items
                || candidate.pinnedItemCount != snapshot.pinnedItemCount
                || candidate.syncStatus != snapshot.syncStatus else {
            return
        }

        revision &+= 1
        snapshot = DockSnapshot(
            revision: revision,
            items: items,
            pinnedItemCount: pinnedItemCount,
            syncStatus: syncStatus
        )
        onSnapshotChange?(snapshot)
    }

    private func recycleDroppedFiles(_ request: DockDropRequest) {
        let shortcutSnapshots = fileShortcutStore.snapshots(
            for: request.sourceShortcutIDs
        )
        fileOperator.recycle(request.fileURLs) { [weak self] result in
            guard let self else { return }
            let recycledPaths = Set(result.recycledURLs.keys.map {
                $0.standardizedFileURL.path
            })
            let recycledSnapshots = shortcutSnapshots.filter {
                recycledPaths.contains($0.originalURL.standardizedFileURL.path)
            }
            if !recycledSnapshots.isEmpty {
                _ = self.fileShortcutStore.remove(
                    shortcutIDs: recycledSnapshots.map { $0.record.id }
                )
            }
            self.trashUndoService.record(
                recycledURLs: result.recycledURLs,
                shortcutSnapshots: recycledSnapshots
            )
            if !result.recycledURLs.isEmpty {
                self.publishIfNeeded()
            }
            if result.errorDescription != nil || result.recycledURLs.isEmpty {
                self.showTemporaryFailure(
                    result.errorDescription ?? L10n.text("dock.error.unableTrash"),
                    identity: ApplicationIdentity(rawValue: "system:trash")
                )
                NSSound.beep()
            }
        }
    }

    private func activateRunningApplication(
        _ item: DockItem,
        candidates: [NSRunningApplication]? = nil
    ) {
        let applications = candidates ?? runningMonitor.instances(for: item.identity)
        guard let application = applications.sorted(by: preferredApplication).first else {
            runningMonitor.reconcile()
            launchApplication(item)
            return
        }

        guard !application.isTerminated else {
            runningMonitor.reconcile()
            launchApplication(item)
            return
        }

        activationService.reopen(
            application,
            applicationURL: application.bundleURL ?? item.applicationURL
        ) { [weak self] error in
            guard let self, let error else { return }
            let message = error.localizedDescription.isEmpty
                ? L10n.format("dock.error.unableSwitch", item.displayName)
                : error.localizedDescription
            self.showTemporaryFailure(message, identity: item.identity)
        }
    }

    private func launchApplication(_ item: DockItem) {
        let identity = item.identity
        guard transientStateByIdentity[identity] != .launching else { return }
        let generation = launchGenerationGate.begin(for: identity)
        launchTimeoutWorkItems[identity]?.cancel()
        launchCompletionGenerations.removeValue(forKey: identity)
        transientStateByIdentity[identity] = .launching
        publishIfNeeded()

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.launchGenerationGate.isCurrent(generation, for: identity) else { return }
            self.launchTimeoutWorkItems.removeValue(forKey: identity)
            self.launchCompletionGenerations.removeValue(forKey: identity)
            guard self.launchGenerationGate.invalidate(generation, for: identity) else { return }
            self.showTemporaryFailure(L10n.text("dock.error.launchTimeout"), identity: identity)
        }
        launchTimeoutWorkItems[identity] = timeoutWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.launchTimeout,
            execute: timeoutWorkItem
        )

        let configuration = RunningApplicationActivationService
            .launchConfiguration()
        workspace.openApplication(at: item.applicationURL, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.finishLaunch(
                    for: identity,
                    generation: generation,
                    error: error
                )
            }
        }
    }

    private func finishLaunch(
        for identity: ApplicationIdentity,
        generation: UInt64,
        error: Error?
    ) {
        guard launchGenerationGate.isCurrent(generation, for: identity) else { return }

        if let error {
            launchTimeoutWorkItems.removeValue(forKey: identity)?.cancel()
            launchCompletionGenerations.removeValue(forKey: identity)
            guard launchGenerationGate.invalidate(generation, for: identity) else { return }
            showTemporaryFailure(error.localizedDescription, identity: identity)
        } else {
            // NSWorkspace can finish before the process has appeared in the
            // running list. Keep the launch state until that is confirmed.
            launchCompletionGenerations[identity] = generation
            runningMonitor.reconcile()
            if runningMonitor.records.contains(where: { $0.identity == identity }) {
                completeLaunch(for: identity, generation: generation)
            }
        }
    }

    private func handleRunningApplicationChange() {
        let runningIdentities = Set(runningMonitor.records.map(\.identity))

        for identity in Array(systemLaunchPulseGenerations.keys)
        where runningIdentities.contains(identity) {
            systemLaunchPulseGenerations.removeValue(forKey: identity)
            systemLaunchTimeoutWorkItems.removeValue(forKey: identity)?.cancel()
            if transientStateByIdentity[identity] == .launching {
                transientStateByIdentity.removeValue(forKey: identity)
            }
        }

        let completedLaunches = runningIdentities.compactMap { identity in
            launchGenerationGate.activeGeneration(for: identity).map {
                (identity, $0)
            }
        }
        for (identity, generation) in completedLaunches {
            completeLaunch(for: identity, generation: generation)
        }
        publishIfNeeded()
    }

    private func completeLaunch(
        for identity: ApplicationIdentity,
        generation: UInt64
    ) {
        guard launchGenerationGate.isCurrent(generation, for: identity) else { return }
        launchCompletionGenerations.removeValue(forKey: identity)
        launchTimeoutWorkItems.removeValue(forKey: identity)?.cancel()
        guard launchGenerationGate.invalidate(generation, for: identity) else { return }
        if transientStateByIdentity[identity] == .launching {
            transientStateByIdentity.removeValue(forKey: identity)
        }
        publishIfNeeded()
    }

    private func showTemporaryFailure(_ message: String, identity: ApplicationIdentity) {
        failureDismissalWorkItems.removeValue(forKey: identity)?.cancel()
        failureDismissalGeneration &+= 1
        let generation = failureDismissalGeneration
        failureDismissalGenerations[identity] = generation
        transientStateByIdentity[identity] = .failed(message)
        publishIfNeeded()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.failureDismissalGenerations[identity] == generation else { return }
            self.failureDismissalGenerations.removeValue(forKey: identity)
            self.failureDismissalWorkItems.removeValue(forKey: identity)
            guard case .failed = self.transientStateByIdentity[identity] else { return }
            self.transientStateByIdentity[identity] = .normal
            self.publishIfNeeded()
        }
        failureDismissalWorkItems[identity] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.failureDisplayDuration,
            execute: workItem
        )
    }

    private func scheduleHideVerification(
        for item: DockItem,
        applications: [NSRunningApplication]
    ) {
        let identity = item.identity
        hideVerificationWorkItems.removeValue(forKey: identity)?.cancel()
        hideVerificationGeneration &+= 1
        let generation = hideVerificationGeneration
        hideVerificationGenerations[identity] = generation

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.hideVerificationGenerations[identity] == generation else { return }
            self.hideVerificationGenerations.removeValue(forKey: identity)
            self.hideVerificationWorkItems.removeValue(forKey: identity)

            self.runningMonitor.reconcile()
            if self.activationService.areHiddenOrTerminated(applications) {
                self.clearTemporaryFailure(for: identity)
            } else {
                self.showTemporaryFailure(
                    L10n.format("dock.error.unableHide", item.displayName),
                    identity: identity
                )
            }
        }
        hideVerificationWorkItems[identity] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.hideVerificationDelay,
            execute: workItem
        )
    }

    private func cancelHideVerification(for identity: ApplicationIdentity) {
        hideVerificationWorkItems.removeValue(forKey: identity)?.cancel()
        hideVerificationGenerations.removeValue(forKey: identity)
    }

    private func clearTemporaryFailure(for identity: ApplicationIdentity) {
        failureDismissalWorkItems.removeValue(forKey: identity)?.cancel()
        failureDismissalGenerations.removeValue(forKey: identity)
        guard case .failed = transientStateByIdentity[identity] else { return }
        transientStateByIdentity.removeValue(forKey: identity)
        publishIfNeeded()
    }

    private func preferredApplication(_ lhs: NSRunningApplication, _ rhs: NSRunningApplication) -> Bool {
        if lhs.isActive != rhs.isActive { return lhs.isActive }
        if lhs.isHidden != rhs.isHidden { return !lhs.isHidden }
        return (lhs.launchDate ?? .distantFuture) < (rhs.launchDate ?? .distantFuture)
    }

    private func currentRunningApplications(for item: DockItem) -> [NSRunningApplication] {
        let matchingApplications = runningApplicationsProvider().filter { application in
            guard !application.isTerminated else { return false }
            guard isControllableRunningApplication(application) else { return false }
            return ApplicationIdentity(
                bundleIdentifier: application.bundleIdentifier,
                applicationURL: application.bundleURL
            ) == item.identity
        }

        let preferredIndices = RunningApplicationURLDisambiguator.preferredIndices(
            candidateURLs: matchingApplications.map(\.bundleURL),
            targetURL: item.applicationURL
        )
        return preferredIndices.map { matchingApplications[$0] }
    }

    private func preferredProcessIdentifiers(for item: DockItem) -> [pid_t] {
        currentRunningApplications(for: item)
            .sorted(by: preferredApplication)
            .map(\.processIdentifier)
    }
}
