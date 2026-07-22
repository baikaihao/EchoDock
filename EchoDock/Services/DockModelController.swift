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

    init(
        workspace: WorkspaceApplicationOpening,
        operations: RunningApplicationOperating? = nil
    ) {
        self.workspace = workspace
        self.operations = operations ?? SystemRunningApplicationOperations()
    }

    func reopen(
        _ application: NSRunningApplication,
        applicationURL: URL,
        completion: @escaping (Error?) -> Void
    ) {
        let activatedBeforeReopen = prepareForForeground(application)
        let configuration = Self.reopenConfiguration(for: application)

        workspace.openApplication(at: applicationURL, configuration: configuration) { [weak self] reopenedApplication, error in
            DispatchQueue.main.async {
                guard let self else { return }

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
    }

    func hide(_ applications: [NSRunningApplication]) -> Bool {
        guard !applications.isEmpty else { return false }
        let requestsSucceeded = perform(applications, operation: operations.hide)
        return requestsSucceeded || areHiddenOrTerminated(applications)
    }

    func areHiddenOrTerminated(_ applications: [NSRunningApplication]) -> Bool {
        applications.allSatisfy { application in
            operations.isTerminated(application) || operations.isHidden(application)
        }
    }

    func activateAllWindows(_ applications: [NSRunningApplication]) -> Bool {
        perform(applications, operation: prepareForForeground)
    }

    func terminate(_ applications: [NSRunningApplication]) -> Bool {
        perform(applications, operation: operations.terminate)
    }

    static func reopenConfiguration(
        for application: NSRunningApplication
    ) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = true
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
    static let launchTimeout: TimeInterval = 8
    static let failureDisplayDuration: TimeInterval = 5
    static let hideVerificationDelay: TimeInterval = 0.15

    var onSnapshotChange: ((DockSnapshot) -> Void)?

    private let preferencesReader: DockPreferencesReading
    private let metadataResolver: ApplicationMetadataResolving
    private let preferenceMonitor: DockPreferenceMonitor
    private let runningMonitor: RunningApplicationMonitoring
    private let cache: PinnedApplicationCache
    private let preferences: PreferencesStore
    private let workspace: NSWorkspace
    private let activationService: RunningApplicationActivationService
    private let applicationWindowService: ApplicationWindowControlling
    private let runningApplicationsProvider: () -> [NSRunningApplication]
    private let isControllableRunningApplication: (NSRunningApplication) -> Bool

    private var pinnedApplications: [PinnedApplication] = []
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
    private var revision: UInt64 = 0
    private var preferencesObserver: NSObjectProtocol?
    private(set) var snapshot: DockSnapshot = .empty

    init(
        preferencesReader: DockPreferencesReading = DockPreferencesReader(),
        metadataResolver: ApplicationMetadataResolving = ApplicationMetadataResolver(),
        preferenceMonitor: DockPreferenceMonitor? = nil,
        runningMonitor: RunningApplicationMonitoring? = nil,
        cache: PinnedApplicationCache = PinnedApplicationCache(),
        preferences: PreferencesStore,
        workspace: NSWorkspace = .shared,
        activationService: RunningApplicationActivationService? = nil,
        applicationWindowService: ApplicationWindowControlling? = nil,
        runningApplicationsProvider: (() -> [NSRunningApplication])? = nil,
        isControllableRunningApplication: ((NSRunningApplication) -> Bool)? = nil
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
            ?? SystemApplicationWindowService(
                adapter: SystemApplicationWindowAccessibilityAdapter()
            )
        self.runningApplicationsProvider = runningApplicationsProvider
            ?? { workspace.runningApplications }
        self.isControllableRunningApplication = isControllableRunningApplication
            ?? { $0.activationPolicy == .regular }
    }

    func start() {
        if let cached = cache.load() {
            pinnedApplications = cached
            syncStatus = .cached
            publishIfNeeded()
        }

        preferenceMonitor.onPossibleChange = { [weak self] in
            self?.refreshDockItems()
        }
        runningMonitor.onChange = { [weak self] in
            self?.publishIfNeeded()
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
        launchTimeoutWorkItems.values.forEach { $0.cancel() }
        launchTimeoutWorkItems.removeAll()
        hideVerificationWorkItems.values.forEach { $0.cancel() }
        hideVerificationWorkItems.removeAll()
        hideVerificationGenerations.removeAll()
        failureDismissalWorkItems.values.forEach { $0.cancel() }
        failureDismissalWorkItems.removeAll()
        failureDismissalGenerations.removeAll()
        systemLaunchPulseGenerations.removeAll()
        transientStateByIdentity.removeAll()
        launchGenerationGate.invalidateAll()
        preferenceMonitor.stop()
        runningMonitor.onChange = nil
        runningMonitor.onApplicationWillLaunch = nil
        runningMonitor.stop()
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
        preferencesObserver = nil
    }

    func refresh() {
        runningMonitor.reconcile()
        refreshDockItems()
    }

    func performPrimaryAction(for item: DockItem) {
        cancelHideVerification(for: item.identity)
        if item.isRunning {
            activateRunningApplication(item)
        } else {
            launchApplication(item)
        }
    }

    func handleSystemApplicationWillLaunch(_ identity: ApplicationIdentity) {
        guard Self.shouldAnimateSystemLaunch(for: identity, in: snapshot) else { return }

        systemLaunchPulseGeneration &+= 1
        let generation = systemLaunchPulseGeneration
        systemLaunchPulseGenerations[identity] = generation
        transientStateByIdentity[identity] = .launching
        publishIfNeeded()

        // The view only needs one published normal -> launching edge. Its
        // fixed bounce timeline keeps playing after the model returns to the
        // normal state, just as it does for launches initiated by EchoDock.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.systemLaunchPulseGenerations[identity] == generation else { return }
            self.systemLaunchPulseGenerations.removeValue(forKey: identity)
            guard self.transientStateByIdentity[identity] == .launching else { return }
            self.transientStateByIdentity.removeValue(forKey: identity)
            self.publishIfNeeded()
        }
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
        guard item.isRunning else { return .unavailable }
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
        cancelHideVerification(for: item.identity)
        switch action {
        case .revealInFinder:
            workspace.activateFileViewerSelecting([item.applicationURL])

        case .open:
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
            switch applicationWindowService.closePreferredWindow(
                processIdentifiers: processIdentifiers
            ) {
            case .requested, .noClosableWindow:
                break
            case .permissionDenied:
                showTemporaryFailure(
                    L10n.text("dock.error.accessibilityClose"),
                    identity: item.identity
                )
            case .failed:
                showTemporaryFailure(
                    L10n.format("dock.error.unableClose", item.displayName),
                    identity: item.identity
                )
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
        }
    }

    private func refreshDockItems() {
        do {
            let entries = try preferencesReader.readEntries()

            var seenApplications = Set<ApplicationIdentity>()
            let resolvedApplicationEntries = entries.compactMap(metadataResolver.resolve)
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
                syncStatus = cachedApplicationsStatus(L10n.text("dock.error.parsePinnedApps"))
            } else {
                pinnedApplications = resolvedApplications
                cache.save(resolvedApplications)
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
        if let cached = cache.load() {
            pinnedApplications = cached
            return .cached
        } else {
            return .unavailable(message)
        }
    }

    private func publishIfNeeded() {
        let buildResult = DockSnapshotBuilder.build(
            finder: metadataResolver.finderApplication(),
            pinnedApplications: pinnedApplications,
            runningApplications: runningMonitor.records,
            showRunningApplications: preferences.showRunningApplications,
            transientStates: transientStateByIdentity
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
        transientStateByIdentity[identity] = .launching
        publishIfNeeded()

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.launchGenerationGate.isCurrent(generation, for: identity) else { return }
            self.launchTimeoutWorkItems.removeValue(forKey: identity)
            guard self.launchGenerationGate.invalidate(generation, for: identity) else { return }
            self.showTemporaryFailure(L10n.text("dock.error.launchTimeout"), identity: identity)
        }
        launchTimeoutWorkItems[identity] = timeoutWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.launchTimeout,
            execute: timeoutWorkItem
        )

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
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
        launchTimeoutWorkItems.removeValue(forKey: identity)?.cancel()
        guard launchGenerationGate.invalidate(generation, for: identity) else { return }

        if let error {
            showTemporaryFailure(error.localizedDescription, identity: identity)
        } else {
            transientStateByIdentity[identity] = .normal
            runningMonitor.reconcile()
            publishIfNeeded()
        }
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
