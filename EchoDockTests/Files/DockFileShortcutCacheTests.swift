import Foundation
import Testing
@testable import EchoDock

@MainActor
struct DockFileShortcutCacheTests {
    @Test
    func passiveSnapshotsReuseResolutionUntilExpiryAndExplicitRefreshInvalidatesIt() throws {
        let suite = "DockFileShortcutCacheTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let file = root.appendingPathComponent("document.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        var time: TimeInterval = 0
        let store = DockFileShortcutStore(defaults: defaults, currentTime: { time })
        store.insert(fileURLs: [file], at: 0)
        #expect(store.resolvedShortcuts.first?.isAvailable == true)
        try FileManager.default.removeItem(at: file)
        #expect(store.resolvedShortcuts.first?.isAvailable == true)
        time = 5
        #expect(store.resolvedShortcuts.first?.isAvailable == false)

        try "restored".write(to: file, atomically: true, encoding: .utf8)
        store.invalidateResolvedShortcuts()
        #expect(store.resolvedShortcuts.first?.isAvailable == true)
    }

    @Test
    func explicitEditsUseFreshBookmarkPathsForDuplicateDetection() throws {
        let suite = "DockFileShortcutCacheTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let old = root.appendingPathComponent("old.txt")
        let moved = root.appendingPathComponent("new.txt")
        try "original".write(to: old, atomically: true, encoding: .utf8)
        let store = DockFileShortcutStore(defaults: defaults)
        store.insert(fileURLs: [old], at: 0)
        _ = store.resolvedShortcuts
        try FileManager.default.moveItem(at: old, to: moved)

        store.insert(fileURLs: [moved], at: 0)

        #expect(store.records.count == 1)
        #expect(store.resolvedShortcuts.first?.url == moved)
    }
}
