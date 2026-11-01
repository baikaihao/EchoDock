import AppKit
import Testing
@testable import EchoDock

@MainActor
struct DockIncrementalRefreshTests {
    @Test
    func unchangedPollsAndRunningStateChangesReuseMetadataAndDoNotSaveAgain() throws {
        let fixture = try RefreshFixture()
        defer { fixture.controller.stop() }
        fixture.controller.start()
        let resolved = fixture.resolver.resolvedNames
        let finderCalls = fixture.resolver.finderCalls
        for second in 1..<30 {
            fixture.time = TimeInterval(second)
            fixture.poll()
            fixture.monitor.onChange?()
        }
        #expect(fixture.resolver.resolvedNames == resolved)
        #expect(fixture.resolver.finderCalls == finderCalls)
        #expect(fixture.cache.saves.count == 1)
    }

    @Test
    func reorderingOnlyUpdatesPresentationAndAddingAnAppOnlyResolvesTheNewApp() throws {
        let fixture = try RefreshFixture()
        defer { fixture.controller.stop() }
        fixture.controller.start()
        let baseline = fixture.resolver.resolvedNames
        fixture.reader.entries = [RefreshFixture.entry("Second", order: 0), RefreshFixture.entry("First", order: 1)]
        fixture.poll()

        #expect(fixture.applicationNames == ["Second", "First"])
        #expect(fixture.resolver.resolvedNames == baseline)
        fixture.reader.entries.append(RefreshFixture.entry("Third", order: 2))
        fixture.poll()
        #expect(fixture.applicationNames == ["Second", "First", "Third"])
        #expect(fixture.resolver.resolvedNames == baseline + ["Third"])
    }

    @Test
    func readFailureKeepsMemoryStateAndRecoveryPublishesNormalWithoutReparsing() throws {
        let fixture = try RefreshFixture()
        defer { fixture.controller.stop() }
        fixture.controller.start()
        let baseline = fixture.resolver.resolvedNames
        let names = fixture.applicationNames
        fixture.reader.shouldFail = true
        fixture.poll()
        #expect(fixture.controller.snapshot.syncStatus == .cached)
        #expect(fixture.applicationNames == names)
        #expect(fixture.cache.loadCount == 1)

        fixture.reader.shouldFail = false
        fixture.poll()
        #expect(fixture.controller.snapshot.syncStatus == .normal)
        #expect(fixture.resolver.resolvedNames == baseline)
        #expect(fixture.cache.saves.count == 1)
    }

    @Test
    func manualRefreshAndExpiryPickUpAppChangesWithoutDockPreferenceChanges() throws {
        let fixture = try RefreshFixture()
        defer { fixture.controller.stop() }
        fixture.controller.start()
        fixture.resolver.nameSuffix = " updated"
        fixture.controller.refresh()
        #expect(fixture.applicationNames == ["First updated", "Second updated"])

        fixture.resolver.nameSuffix = " newer"
        fixture.time = DockModelController.metadataRefreshInterval
        fixture.poll()
        #expect(fixture.applicationNames == ["First newer", "Second newer"])
        let saveCount = fixture.cache.saves.count
        fixture.controller.refresh()
        #expect(fixture.cache.saves.count == saveCount)
    }

    @Test
    func failedResolutionIsRetriedAndAnInvalidationBypassesTheCache() throws {
        let fixture = try RefreshFixture()
        defer { fixture.controller.stop() }
        fixture.resolver.canResolve = false
        fixture.controller.start()
        #expect(fixture.applicationNames.isEmpty)
        let baseline = fixture.resolver.resolvedNames.count
        fixture.time = 1
        fixture.poll()
        #expect(fixture.resolver.resolvedNames.count == baseline)

        fixture.resolver.canResolve = true
        fixture.time = DockModelController.failedResolutionRetryInterval
        fixture.poll()
        #expect(fixture.applicationNames == ["First", "Second"])
        fixture.resolver.nameSuffix = " changed"
        fixture.preferenceMonitor.onMetadataInvalidation?()
        #expect(fixture.applicationNames == ["First changed", "Second changed"])
    }

    @Test
    func removingAllPinnedAppsPersistsAnEmptyList() throws {
        let fixture = try RefreshFixture()
        defer { fixture.controller.stop() }
        fixture.controller.start()
        fixture.reader.entries = []
        fixture.poll()
        #expect(fixture.applicationNames.isEmpty)
        #expect(fixture.cache.saves.last == [])
        #expect(fixture.controller.snapshot.syncStatus == .normal)
    }
}

@MainActor
private final class RefreshFixture {
    let suite = "DockIncrementalRefreshTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let reader = RefreshReader()
    let resolver = RefreshResolver()
    let cache = RefreshCache()
    let monitor = RefreshMonitor()
    let preferenceMonitor = DockPreferenceMonitor()
    var time: TimeInterval = 0
    lazy var controller = DockModelController(
        preferencesReader: reader, metadataResolver: resolver, preferenceMonitor: preferenceMonitor,
        runningMonitor: monitor, cache: cache, preferences: PreferencesStore(defaults: defaults),
        fileShortcutStore: DockFileShortcutStore(defaults: defaults),
        currentTime: { [unowned self] in time }
    )

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        reader.entries = [Self.entry("First", order: 0), Self.entry("Second", order: 1)]
    }

    deinit { defaults.removePersistentDomain(forName: suite) }

    func poll() { preferenceMonitor.onPossibleChange?() }

    var applicationNames: [String] { controller.snapshot.items.filter(\.kind.isApplication).map(\.displayName) }

    static func entry(_ name: String, order: Int) -> DockPreferenceEntry {
        DockPreferenceEntry(bundleIdentifier: "test.\(name)", primaryURL: URL(fileURLWithPath: "/Applications/\(name).app"),
                            bookmarkData: nil, fallbackName: name, sourceOrder: order)
    }
}

private final class RefreshReader: DockPreferencesReading {
    var entries: [DockPreferenceEntry] = []
    var shouldFail = false
    func readEntries() throws -> [DockPreferenceEntry] {
        if shouldFail { throw DockPreferencesError.unavailable }
        return entries
    }
}

private final class RefreshResolver: ApplicationMetadataResolving {
    var resolvedNames: [String] = []
    var finderCalls = 0
    var nameSuffix = ""
    var canResolve = true
    func resolve(_ entry: DockPreferenceEntry) -> PinnedApplication? {
        let name = entry.fallbackName ?? ""
        resolvedNames.append(name)
        guard canResolve, let url = entry.primaryURL else { return nil }
        return PinnedApplication(identity: ApplicationIdentity(bundleIdentifier: entry.bundleIdentifier, applicationURL: url),
                                 bundleIdentifier: entry.bundleIdentifier, applicationURL: url,
                                 displayName: name + nameSuffix, sourceOrder: entry.sourceOrder)
    }
    func finderApplication() -> PinnedApplication? { finderCalls += 1; return nil }
}

private final class RefreshCache: PinnedApplicationCaching {
    var loadCount = 0
    var saves: [[PinnedApplication]] = []
    func load() -> [PinnedApplication]? { loadCount += 1; return saves.last }
    func save(_ applications: [PinnedApplication]) { saves.append(applications) }
}

@MainActor
private final class RefreshMonitor: RunningApplicationMonitoring {
    var onChange: (() -> Void)?
    var onApplicationWillLaunch: ((ApplicationIdentity) -> Void)?
    var records: [RunningApplicationRecord] = []
    func start() {}
    func stop() {}
    func reconcile() { onChange?() }
    func instances(for identity: ApplicationIdentity) -> [NSRunningApplication] { [] }
}
