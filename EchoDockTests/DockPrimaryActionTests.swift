import AppKit
import XCTest
@testable import EchoDock

final class DockPrimaryActionTests: XCTestCase {
    @MainActor
    func testActiveWindowMinimizesUsingLiveStateInsteadOfStaleSnapshot() {
        let fixture = PrimaryActionFixture()
        fixture.operations.set(fixture.first, active: true)

        fixture.controller.performPrimaryAction(for: fixture.item(active: false))

        XCTAssertEqual(fixture.windows.events, [.restore, .minimize])
        XCTAssertTrue(fixture.operations.events.isEmpty)
        XCTAssertTrue(fixture.workspace.requests.isEmpty)
    }

    @MainActor
    func testBackgroundApplicationActivatesDespiteStaleActiveSnapshot() {
        let fixture = PrimaryActionFixture()
        fixture.controller.performPrimaryAction(for: fixture.item(active: true))

        XCTAssertEqual(fixture.windows.events, [.restore])
        XCTAssertEqual(fixture.operations.events, [.activate(101)])
        XCTAssertEqual(fixture.workspace.requests.count, 1)
        XCTAssertFalse(fixture.workspace.requests[0].configuration.activates)
        XCTAssertNotNil(fixture.workspace.requests[0].configuration.appleEvent)
    }

    @MainActor
    func testActiveApplicationWithoutVisibleWindowsReopens() {
        let fixture = PrimaryActionFixture()
        fixture.operations.set(fixture.first, active: true)
        fixture.visiblePIDs = []

        fixture.controller.performPrimaryAction(for: fixture.item(active: true))

        XCTAssertEqual(fixture.windows.events, [.restore])
        XCTAssertEqual(fixture.workspace.requests.count, 1)
        XCTAssertEqual(fixture.operations.events, [.activate(101)])
    }

    @MainActor
    func testRestorationActivatesOnlyTheInstanceWhoseWindowWasRestored() {
        let fixture = PrimaryActionFixture()
        let otherInstance = PrimaryActionApplication(pid: 102, url: fixture.first.bundleURL!, active: true)
        fixture.runningApplications = [otherInstance, fixture.first]
        fixture.operations.set(otherInstance, active: true)
        fixture.windows.restoreResult = .restored(processIdentifier: 101)

        fixture.controller.performPrimaryAction(for: fixture.item(active: true))

        XCTAssertEqual(fixture.windows.events, [.restore])
        XCTAssertEqual(fixture.operations.events, [.activate(101)])
        XCTAssertTrue(fixture.workspace.requests.isEmpty)
    }

    @MainActor
    func testMinimizationFailuresNeverFallBackToHidingOrReopening() {
        for result: ApplicationWindowMinimizeResult in [.permissionDenied, .noMinimizableWindow, .failed] {
            let fixture = PrimaryActionFixture()
            fixture.operations.set(fixture.first, active: true)
            fixture.windows.minimizeResult = result

            fixture.controller.performPrimaryAction(for: fixture.item())

            XCTAssertEqual(fixture.windows.events, [.restore, .minimize])
            XCTAssertTrue(fixture.operations.events.isEmpty)
            XCTAssertTrue(fixture.workspace.requests.isEmpty)
            fixture.controller.stop()
        }
    }

    @MainActor
    func testFilesAndTrashKeepTheirOriginalOpenBehavior() {
        let fixture = PrimaryActionFixture()
        fixture.controller.performPrimaryAction(for: fixture.item(kind: .fileShortcut(id: UUID(), isDirectory: false, isAvailable: true)))
        fixture.controller.performPrimaryAction(for: fixture.item(kind: .trash))
        fixture.controller.performPrimaryAction(for: fixture.item(kind: .dropPlaceholder))

        XCTAssertEqual(fixture.workspace.openedURLs.count, 2)
        XCTAssertTrue(fixture.workspace.requests.isEmpty)
        XCTAssertTrue(fixture.windows.events.isEmpty)
        XCTAssertTrue(fixture.operations.events.isEmpty)
    }

    @MainActor
    func testMinimizationReappliesOnlyTheRememberedWindowAfterStaleReopen() async {
        let fixture = PrimaryActionFixture()
        fixture.reopen(fixture.first)
        fixture.controller.performPrimaryAction(for: fixture.item())
        fixture.windows.focusedWindow = "second-window"
        let eventsBeforeCompletion = fixture.operations.events

        fixture.workspace.requests[0].completion?(fixture.first, nil)
        await drainMainQueue()

        XCTAssertEqual(fixture.operations.events, eventsBeforeCompletion)
        XCTAssertEqual(fixture.windows.events, [.restore, .minimize, .reapply])
        XCTAssertEqual(fixture.windows.reappliedWindows, ["first-window"])
    }

    @MainActor
    func testRestorationSupersedesStaleMinimizationCorrection() async {
        let fixture = PrimaryActionFixture()
        fixture.reopen(fixture.first)
        fixture.controller.performPrimaryAction(for: fixture.item())
        fixture.windows.restoreResult = .restored(processIdentifier: 101)
        fixture.controller.performPrimaryAction(for: fixture.item())
        let eventsBeforeCompletion = fixture.operations.events

        fixture.workspace.requests[0].completion?(fixture.first, nil)
        await drainMainQueue()

        XCTAssertTrue(fixture.windows.reappliedWindows.isEmpty)
        XCTAssertEqual(fixture.operations.events, eventsBeforeCompletion)
    }

    @MainActor
    func testNewApplicationIntentCancelsPreviousApplicationsDelayedCompletion() async {
        let fixture = PrimaryActionFixture()
        fixture.reopen(fixture.first)
        fixture.reopen(fixture.second)
        let eventsBeforeCompletion = fixture.operations.events

        fixture.workspace.requests[0].completion?(fixture.first, nil)
        await drainMainQueue()

        XCTAssertEqual(fixture.operations.events, eventsBeforeCompletion)
        XCTAssertTrue(fixture.operations.isActive(fixture.second))
        XCTAssertFalse(fixture.operations.isActive(fixture.first))
    }

    @MainActor
    func testNewApplicationIntentCancelsPreviousApplicationsForegroundRetries() async throws {
        let fixture = PrimaryActionFixture()
        fixture.operations.successfulActivationAttempt[101] = .max
        fixture.reopen(fixture.first)
        fixture.reopen(fixture.second)

        try await waitForRetries()

        XCTAssertEqual(fixture.operations.activationAttempts[101], 1)
        XCTAssertEqual(fixture.operations.activationAttempts[102], 1)
        XCTAssertTrue(fixture.operations.isActive(fixture.second))
    }

    @MainActor
    func testLaunchingAnotherApplicationCancelsPendingActivationForTheFirst() async throws {
        let fixture = PrimaryActionFixture()
        fixture.operations.successfulActivationAttempt[101] = .max
        fixture.reopen(fixture.first)
        fixture.controller.performPrimaryAction(for: fixture.item(application: fixture.second))

        fixture.workspace.requests[0].completion?(fixture.first, nil)
        await drainMainQueue()
        try await waitForRetries()

        XCTAssertEqual(fixture.workspace.requests.count, 2)
        XCTAssertEqual(fixture.operations.activationAttempts[101], 1)
        fixture.controller.stop()
    }

    @MainActor
    func testHideKeepsItsStaleCompletionCorrectionAfterAnotherAppIsOpened() async {
        let fixture = PrimaryActionFixture()
        fixture.reopen(fixture.first)
        XCTAssertTrue(fixture.service.hide([fixture.first]))
        fixture.reopen(fixture.second)
        let activations = fixture.operations.activationAttempts

        fixture.workspace.requests[0].completion?(fixture.first, nil)
        await drainMainQueue()

        XCTAssertEqual(fixture.operations.activationAttempts, activations)
        XCTAssertEqual(fixture.operations.events.last, .hide(101))
        XCTAssertTrue(fixture.operations.isActive(fixture.second))
    }

    @MainActor
    func testQuitDoesNotHideASaveConfirmationWhenOldReopenCompletes() async throws {
        let fixture = PrimaryActionFixture()
        fixture.reopen(fixture.first)
        XCTAssertTrue(fixture.service.terminate([fixture.first]))
        // A successful terminate request need not mean the process has exited.
        XCTAssertFalse(fixture.operations.isTerminated(fixture.first))
        let events = fixture.operations.events

        fixture.workspace.requests[0].completion?(fixture.first, nil)
        await drainMainQueue()
        try await waitForRetries()

        XCTAssertEqual(fixture.operations.events, events)
        XCTAssertFalse(fixture.operations.isHidden(fixture.first))
    }

    @MainActor
    func testForegroundVerificationRetriesUntilActivationTakesEffect() async throws {
        let fixture = PrimaryActionFixture()
        fixture.operations.successfulActivationAttempt[101] = 3
        fixture.reopen(fixture.first)

        try await waitForRetries()

        XCTAssertTrue(fixture.operations.isActive(fixture.first))
        XCTAssertEqual(fixture.operations.activationAttempts[101], 3)
        XCTAssertEqual(fixture.workspace.requests.count, 1)
    }

    @MainActor
    func testDelayedUnhideIsFollowedByActivationWithoutASecondReopen() async throws {
        let fixture = PrimaryActionFixture()
        fixture.operations.set(fixture.first, hidden: true)
        fixture.operations.unhideImmediately = false
        fixture.reopen(fixture.first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            fixture.operations.set(fixture.first, hidden: false)
        }

        try await waitForRetries()

        XCTAssertTrue(fixture.operations.isActive(fixture.first))
        XCTAssertFalse(fixture.operations.isHidden(fixture.first))
        XCTAssertEqual(fixture.workspace.requests.count, 1)
    }

    @MainActor
    func testMinimizationCancelsPendingForegroundRetries() async throws {
        let fixture = PrimaryActionFixture()
        fixture.operations.successfulActivationAttempt[101] = .max
        fixture.reopen(fixture.first)
        fixture.operations.set(fixture.first, active: true)
        fixture.controller.performPrimaryAction(for: fixture.item())
        fixture.operations.set(fixture.first, active: false)

        try await waitForRetries()

        XCTAssertEqual(fixture.operations.activationAttempts[101], 1)
        XCTAssertEqual(fixture.windows.rememberedWindow, "first-window")
    }

    @MainActor
    func testUnsuccessfulActivationHasABoundedRetryBudget() async throws {
        let fixture = PrimaryActionFixture()
        fixture.operations.successfulActivationAttempt[101] = .max
        fixture.reopen(fixture.first)
        try await waitForRetries()
        let attempts = fixture.operations.activationAttempts[101] ?? 0
        XCTAssertGreaterThan(attempts, 1)
        XCTAssertLessThanOrEqual(attempts, 4)

        try await waitForRetries()

        XCTAssertEqual(fixture.operations.activationAttempts[101], attempts)
        XCTAssertEqual(fixture.workspace.requests.count, 1)
    }

    @MainActor
    func testMultiInstanceShowVerifiesOnlyThePreferredLastInstance() async throws {
        let fixture = PrimaryActionFixture()
        fixture.operations.successfulActivationAttempt[101] = .max
        fixture.operations.successfulActivationAttempt[102] = 2

        XCTAssertTrue(fixture.service.activateAllWindows([fixture.first, fixture.second]))
        try await waitForRetries()

        XCTAssertEqual(fixture.operations.activationAttempts[101], 1)
        XCTAssertEqual(fixture.operations.activationAttempts[102], 2)
        XCTAssertTrue(fixture.operations.isActive(fixture.second))
    }

    func testVisibleWindowFilteringRejectsNonWindowLayersTransparencyAndEmptyBounds() {
        func window(pid: Int, layer: Int = 0, alpha: Double = 1, bounds: CGRect = CGRect(x: -400, y: 0, width: 300, height: 200)) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: pid),
             kCGWindowLayer as String: NSNumber(value: layer),
             kCGWindowAlpha as String: NSNumber(value: alpha),
             kCGWindowBounds as String: bounds.dictionaryRepresentation]
        }
        let windows = [window(pid: 1), window(pid: 1), window(pid: 2, layer: 1), window(pid: 3, alpha: 0), window(pid: 4, bounds: .zero), [:]]
        XCTAssertEqual(VisibleApplicationWindows.processIdentifiers(in: windows), [1])
    }

    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private func waitForRetries() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
        await drainMainQueue()
    }
}

// Synthetic NSRunningApplication objects provide identity only. Every opening,
// activation and accessibility operation below is intercepted by a test double.
private final class PrimaryActionApplication: NSRunningApplication, @unchecked Sendable {
    private let pid: pid_t
    private let url: URL
    private let stubActive: Bool
    init(pid: pid_t, url: URL, active: Bool = false) {
        self.pid = pid
        self.url = url
        self.stubActive = active
        super.init()
    }
    override var processIdentifier: pid_t { pid }
    override var bundleURL: URL? { url }
    override var bundleIdentifier: String? { "com.example.PrimaryActionTests" }
    override var isTerminated: Bool { false }
    override var isActive: Bool { stubActive }
    override var isHidden: Bool { false }
}

@MainActor
private final class PrimaryActionWorkspace: NSWorkspace {
    struct Request {
        let configuration: NSWorkspace.OpenConfiguration
        let completion: (@Sendable (NSRunningApplication?, Error?) -> Void)?
    }
    var requests: [Request] = []
    var openedURLs: [URL] = []
    override func openApplication(at applicationURL: URL, configuration: NSWorkspace.OpenConfiguration, completionHandler: (@Sendable (NSRunningApplication?, Error?) -> Void)? = nil) {
        requests.append(Request(configuration: configuration, completion: completionHandler))
    }
    override func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }
}

@MainActor
private final class PrimaryActionOperations: RunningApplicationOperating {
    enum Event: Equatable { case activate(pid_t), hide(pid_t), unhide(pid_t), terminate(pid_t) }
    struct State { var active = false; var hidden = false; var terminated = false }
    var states: [pid_t: State] = [:]
    var events: [Event] = []
    var activationAttempts: [pid_t: Int] = [:]
    var successfulActivationAttempt: [pid_t: Int] = [:]
    var unhideImmediately = true
    func set(_ app: NSRunningApplication, active: Bool = false, hidden: Bool = false) {
        states[app.processIdentifier] = State(active: active, hidden: hidden)
    }
    func isActive(_ app: NSRunningApplication) -> Bool { states[app.processIdentifier]?.active ?? false }
    func isHidden(_ app: NSRunningApplication) -> Bool { states[app.processIdentifier]?.hidden ?? false }
    func isTerminated(_ app: NSRunningApplication) -> Bool { states[app.processIdentifier]?.terminated ?? false }
    func unhide(_ app: NSRunningApplication) -> Bool {
        events.append(.unhide(app.processIdentifier))
        if unhideImmediately { states[app.processIdentifier, default: State()].hidden = false }
        return true
    }
    func hide(_ app: NSRunningApplication) -> Bool {
        events.append(.hide(app.processIdentifier))
        states[app.processIdentifier, default: State()].hidden = true
        states[app.processIdentifier, default: State()].active = false
        return true
    }
    func terminate(_ app: NSRunningApplication) -> Bool {
        events.append(.terminate(app.processIdentifier))
        return true
    }
    func activate(_ app: NSRunningApplication, options: NSApplication.ActivationOptions) -> Bool {
        let pid = app.processIdentifier
        events.append(.activate(pid))
        activationAttempts[pid, default: 0] += 1
        if activationAttempts[pid, default: 0] >= successfulActivationAttempt[pid, default: 1] && !isHidden(app) {
            for otherPID in Array(states.keys) { states[otherPID]?.active = false }
            states[pid, default: State()].active = true
        }
        return true
    }
}

@MainActor
private final class PrimaryActionWindows: ApplicationWindowControlling {
    enum Event: Equatable { case minimize, restore, reapply }
    var hasAccessibilityPermission = true
    var minimizeResult = ApplicationWindowMinimizeResult.requested
    var restoreResult = ApplicationWindowRestoreResult.none
    var events: [Event] = []
    var focusedWindow = "first-window"
    var rememberedWindow: String?
    var reappliedWindows: [String] = []
    func canCloseWindow(processIdentifiers: [pid_t]) -> Bool { false }
    func closePreferredWindow(processIdentifiers: [pid_t]) -> ApplicationWindowCloseResult { .noClosableWindow }
    func minimizePreferredWindow(processIdentifiers: [pid_t]) -> ApplicationWindowMinimizeResult {
        events.append(.minimize)
        if minimizeResult == .requested { rememberedWindow = focusedWindow }
        return minimizeResult
    }
    func restoreLastMinimizedWindow(processIdentifiers: [pid_t]) -> ApplicationWindowRestoreResult {
        events.append(.restore)
        if case .restored = restoreResult { rememberedWindow = nil }
        return restoreResult
    }
    func reapplyLastMinimization(processIdentifiers: [pid_t]) -> ApplicationWindowMinimizeResult {
        events.append(.reapply)
        if let rememberedWindow { reappliedWindows.append(rememberedWindow) }
        return .requested
    }
}

@MainActor
private final class PrimaryActionMonitor: RunningApplicationMonitoring {
    var onChange: (() -> Void)?
    var onApplicationWillLaunch: ((ApplicationIdentity) -> Void)?
    var records: [RunningApplicationRecord] = []
    func start() {}
    func stop() {}
    func reconcile() {}
    func instances(for identity: ApplicationIdentity) -> [NSRunningApplication] { [] }
}

@MainActor
private final class PrimaryActionFixture {
    let first = PrimaryActionApplication(pid: 101, url: URL(fileURLWithPath: "/Applications/PrimaryActionFirst.app"))
    let second = PrimaryActionApplication(pid: 102, url: URL(fileURLWithPath: "/Applications/PrimaryActionSecond.app"))
    let workspace = PrimaryActionWorkspace()
    let operations = PrimaryActionOperations()
    let windows = PrimaryActionWindows()
    let monitor = PrimaryActionMonitor()
    var visiblePIDs: Set<pid_t> = [101, 102]
    lazy var runningApplications: [NSRunningApplication] = [first]
    lazy var defaults = UserDefaults(suiteName: "DockPrimaryActionTests.\(UUID().uuidString)")!
    lazy var service = RunningApplicationActivationService(workspace: workspace, operations: operations, visibleWindowProcessIdentifiers: { [unowned self] in visiblePIDs })
    lazy var controller = DockModelController(
        runningMonitor: monitor,
        preferences: PreferencesStore(defaults: defaults),
        workspace: workspace,
        activationService: service,
        applicationWindowService: windows,
        runningApplicationsProvider: { [unowned self] in runningApplications },
        isControllableRunningApplication: { _ in true },
        fileShortcutStore: DockFileShortcutStore(defaults: defaults)
    )
    func item(application: NSRunningApplication? = nil, active: Bool = false, kind: DockItemKind = .application) -> DockItem {
        let app = application ?? first
        return DockItem(identity: ApplicationIdentity(bundleIdentifier: app.bundleIdentifier, applicationURL: app.bundleURL), bundleIdentifier: app.bundleIdentifier, applicationURL: app.bundleURL!, displayName: "Test application", section: .pinned, kind: kind, isRunning: true, isActive: active, isHidden: false, transientState: .normal)
    }
    func reopen(_ app: NSRunningApplication) {
        service.reopen(app, applicationURL: app.bundleURL!) { _ in }
    }
}
