import XCTest
@testable import EchoDock

final class ApplicationIdentityTests: XCTestCase {
    private struct LegacyCachePayload: Codable {
        let version: Int
        let applications: [PinnedApplication]
    }

    private let bundleIdentifier = "com.example.LayeredApp"
    private let installedURL = URL(fileURLWithPath: "/Applications/LayeredApp.app")
    private let debugURL = URL(
        fileURLWithPath: "/Users/test/Library/Developer/Xcode/DerivedData/LayeredApp/Build/Products/Debug/LayeredApp.app"
    )

    func testSameBundleIdentifierAtDifferentApplicationURLsHasDistinctIdentities() {
        let installed = identity(for: installedURL)
        let debug = identity(for: debugURL)

        XCTAssertNotEqual(installed, debug)
    }

    func testEquivalentApplicationURLsHaveSameIdentity() {
        let directURL = URL(fileURLWithPath: "/Applications/LayeredApp.app")
        let standardizedURL = URL(
            fileURLWithPath: "/Applications/Utilities/../LayeredApp.app"
        )

        XCTAssertEqual(identity(for: directURL), identity(for: standardizedURL))
    }

    func testPinnedInstalledBuildAndRunningDebugBuildProduceTwoDockItems() {
        let result = DockSnapshotBuilder.build(
            finder: nil,
            pinnedApplications: [pinnedApplication(at: installedURL)],
            runningApplications: [runningApplication(at: debugURL)],
            showRunningApplications: true,
            transientStates: [:]
        )
        let applications = result.items.filter(\.kind.isApplication)

        XCTAssertEqual(result.pinnedItemCount, 1)
        XCTAssertEqual(applications.count, 2)
        XCTAssertEqual(applications.map(\.section), [.pinned, .running])
        XCTAssertEqual(applications.map(\.applicationURL), [installedURL, debugURL])
        XCTAssertFalse(applications[0].isRunning)
        XCTAssertTrue(applications[1].isRunning)
    }

    func testMultipleRunningRecordsAtSameURLProduceOneRunningDockItem() {
        let result = DockSnapshotBuilder.build(
            finder: nil,
            pinnedApplications: [],
            runningApplications: [
                runningApplication(at: debugURL, stableOrder: 0),
                runningApplication(at: debugURL, stableOrder: 1)
            ],
            showRunningApplications: true,
            transientStates: [:]
        )
        let applications = result.items.filter(\.kind.isApplication)

        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(applications[0].applicationURL, debugURL)
        XCTAssertEqual(applications[0].section, .running)
    }

    func testRunningInstanceAtPinnedURLMarksOnlyPinnedItemRunning() {
        let result = DockSnapshotBuilder.build(
            finder: nil,
            pinnedApplications: [pinnedApplication(at: installedURL)],
            runningApplications: [runningApplication(at: installedURL)],
            showRunningApplications: true,
            transientStates: [:]
        )
        let applications = result.items.filter(\.kind.isApplication)

        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(applications[0].section, .pinned)
        XCTAssertTrue(applications[0].isRunning)
    }

    func testURLDisambiguatorTargetsOnlyTheRequestedBuild() {
        let preferred = RunningApplicationURLDisambiguator.preferredIndices(
            candidateURLs: [installedURL, debugURL],
            targetURL: debugURL
        )

        XCTAssertEqual(preferred, [1])
    }

    func testURLDisambiguatorKeepsEveryInstanceOfTheSameBuild() {
        let preferred = RunningApplicationURLDisambiguator.preferredIndices(
            candidateURLs: [debugURL, debugURL],
            targetURL: debugURL
        )

        XCTAssertEqual(preferred, [0, 1])
    }

    func testPinnedCacheMigratesLegacyBundleOnlyIdentity() throws {
        let suiteName = "ApplicationIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = PinnedApplicationCache(defaults: defaults)
        let legacyApplication = PinnedApplication(
            identity: ApplicationIdentity(rawValue: "bundle:\(bundleIdentifier.lowercased())"),
            bundleIdentifier: bundleIdentifier,
            applicationURL: installedURL,
            displayName: "LayeredApp",
            sourceOrder: 0
        )

        let legacyPayload = LegacyCachePayload(
            version: 1,
            applications: [legacyApplication]
        )
        defaults.set(
            try JSONEncoder().encode(legacyPayload),
            forKey: "lastValidPinnedApplications"
        )
        let migrated = try XCTUnwrap(cache.load()?.first)

        XCTAssertEqual(migrated.identity, identity(for: installedURL))
    }

    @MainActor
    func testOpenConfigurationsDoNotSubstituteAnotherBuild() {
        let launchConfiguration = RunningApplicationActivationService
            .launchConfiguration()
        let reopenConfiguration = RunningApplicationActivationService
            .reopenConfiguration(for: .current)

        XCTAssertFalse(
            launchConfiguration.allowsRunningApplicationSubstitution
        )
        XCTAssertFalse(
            reopenConfiguration.allowsRunningApplicationSubstitution
        )
    }

    private func identity(for url: URL) -> ApplicationIdentity {
        ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            applicationURL: url
        )
    }

    private func pinnedApplication(at url: URL) -> PinnedApplication {
        PinnedApplication(
            identity: identity(for: url),
            bundleIdentifier: bundleIdentifier,
            applicationURL: url,
            displayName: "LayeredApp",
            sourceOrder: 0
        )
    }

    private func runningApplication(
        at url: URL,
        stableOrder: Int = 0
    ) -> RunningApplicationRecord {
        RunningApplicationRecord(
            identity: identity(for: url),
            bundleIdentifier: bundleIdentifier,
            applicationURL: url,
            displayName: "LayeredApp",
            isActive: false,
            isHidden: false,
            stableOrder: stableOrder
        )
    }
}
