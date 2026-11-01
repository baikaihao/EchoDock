import Foundation

struct DockFileShortcutRecord: Codable, Equatable, Sendable {
    let id: UUID
    let bookmark: Data
    let fallbackPath: String
    let displayName: String
    let isDirectory: Bool
}

struct ResolvedDockFileShortcut: Equatable, Sendable {
    let id: UUID
    let url: URL
    let displayName: String
    let isDirectory: Bool
    let isAvailable: Bool
}

struct DockShortcutRecycleSnapshot: Equatable, Sendable {
    let record: DockFileShortcutRecord
    let index: Int
    let originalURL: URL
}

@MainActor
final class DockFileShortcutStore {
    private static let defaultsKey = "thirdSection.fileShortcuts.v1"

    private let defaults: UserDefaults
    private let currentTime: () -> TimeInterval
    private let resolutionLifetime: TimeInterval
    private var resolvedCache: [UUID: CachedResolution] = [:]
    private(set) var records: [DockFileShortcutRecord]

    private struct CachedResolution {
        let record: DockFileShortcutRecord
        let shortcut: ResolvedDockFileShortcut
        let expiresAt: TimeInterval
    }

    init(
        defaults: UserDefaults = .standard,
        resolutionLifetime: TimeInterval = 5,
        currentTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.defaults = defaults
        self.resolutionLifetime = resolutionLifetime
        self.currentTime = currentTime
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([DockFileShortcutRecord].self, from: data) {
            records = decoded
        } else {
            records = []
        }
    }

    var resolvedShortcuts: [ResolvedDockFileShortcut] {
        records.map(resolve)
    }

    func invalidateResolvedShortcuts() {
        resolvedCache.removeAll()
    }

    @discardableResult
    func insert(fileURLs: [URL], at requestedIndex: Int) -> Bool {
        let normalizedURLs = uniqueFileURLs(fileURLs)
        guard !normalizedURLs.isEmpty else { return false }
        // Explicit edits use current paths for duplicate detection, even while
        // passive snapshots are allowed to reuse their short-lived cache.
        invalidateResolvedShortcuts()

        let previousRecords = records
        var insertionIndex = min(max(0, requestedIndex), records.count)
        for url in normalizedURLs {
            if let existingIndex = index(of: url) {
                let record = records.remove(at: existingIndex)
                if existingIndex < insertionIndex { insertionIndex -= 1 }
                records.insert(record, at: min(insertionIndex, records.count))
                insertionIndex += 1
                continue
            }

            guard let record = makeRecord(for: url) else { continue }
            records.insert(record, at: min(insertionIndex, records.count))
            insertionIndex += 1
        }
        guard records != previousRecords else { return false }
        persist()
        return true
    }

    @discardableResult
    func move(shortcutIDs: [UUID], to requestedIndex: Int) -> Bool {
        let ids = shortcutIDs.reduce(into: [UUID]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        let moving = ids.compactMap { id in records.first(where: { $0.id == id }) }
        guard !moving.isEmpty else { return false }

        let oldRecords = records
        let movingIDs = Set(moving.map(\.id))
        let removedBeforeTarget = records.prefix(min(max(0, requestedIndex), records.count))
            .filter { movingIDs.contains($0.id) }
            .count
        records.removeAll { movingIDs.contains($0.id) }
        let insertionIndex = min(
            max(0, requestedIndex - removedBeforeTarget),
            records.count
        )
        records.insert(contentsOf: moving, at: insertionIndex)
        guard records != oldRecords else { return false }
        persist()
        return true
    }

    func snapshots(for shortcutIDs: [UUID]) -> [DockShortcutRecycleSnapshot] {
        let requested = Set(shortcutIDs)
        return records.enumerated().compactMap { index, record in
            guard requested.contains(record.id) else { return nil }
            resolvedCache.removeValue(forKey: record.id)
            let resolved = resolve(record)
            return DockShortcutRecycleSnapshot(
                record: record,
                index: index,
                originalURL: resolved.url
            )
        }
    }

    @discardableResult
    func remove(shortcutIDs: [UUID]) -> Bool {
        let ids = Set(shortcutIDs)
        let oldCount = records.count
        records.removeAll { ids.contains($0.id) }
        guard records.count != oldCount else { return false }
        persist()
        return true
    }

    func restore(_ snapshots: [DockShortcutRecycleSnapshot], restoredURLs: [URL: URL]) {
        for snapshot in snapshots.sorted(by: { $0.index < $1.index }) {
            guard records.allSatisfy({ $0.id != snapshot.record.id }) else { continue }
            let restoredURL = restoredURLs[snapshot.originalURL] ?? snapshot.originalURL
            let record = makeRecord(for: restoredURL, id: snapshot.record.id)
                ?? snapshot.record
            records.insert(record, at: min(snapshot.index, records.count))
        }
        persist()
    }

    private func resolve(_ record: DockFileShortcutRecord) -> ResolvedDockFileShortcut {
        let now = currentTime()
        if let cached = resolvedCache[record.id], cached.record == record, now < cached.expiresAt {
            return cached.shortcut
        }
        var isStale = false
        let resolvedURL = try? URL(
            resolvingBookmarkData: record.bookmark,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let url = (resolvedURL ?? URL(fileURLWithPath: record.fallbackPath))
            .standardizedFileURL
        let isAvailable = FileManager.default.fileExists(atPath: url.path)
        let values = try? url.resourceValues(forKeys: [.nameKey, .isDirectoryKey])
        let shortcut = ResolvedDockFileShortcut(
            id: record.id,
            url: url,
            displayName: values?.name ?? record.displayName,
            isDirectory: values?.isDirectory ?? record.isDirectory,
            isAvailable: isAvailable
        )
        resolvedCache[record.id] = CachedResolution(record: record, shortcut: shortcut, expiresAt: now + resolutionLifetime)
        return shortcut
    }

    private func index(of url: URL) -> Int? {
        let target = canonicalPath(url)
        return records.firstIndex { canonicalPath(resolve($0).url) == target }
    }

    private func makeRecord(for url: URL, id: UUID = UUID()) -> DockFileShortcutRecord? {
        let normalized = url.standardizedFileURL
        guard normalized.isFileURL else { return nil }
        let values = try? normalized.resourceValues(forKeys: [.nameKey, .isDirectoryKey])
        let bookmark = (try? normalized.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
            relativeTo: nil
        )) ?? Data()
        return DockFileShortcutRecord(
            id: id,
            bookmark: bookmark,
            fallbackPath: normalized.path,
            displayName: values?.name ?? normalized.lastPathComponent,
            isDirectory: values?.isDirectory ?? false
        )
    }

    private func uniqueFileURLs(_ urls: [URL]) -> [URL] {
        var paths = Set<String>()
        return urls.compactMap { url in
            guard url.isFileURL else { return nil }
            let normalized = url.standardizedFileURL
            return paths.insert(canonicalPath(normalized)).inserted ? normalized : nil
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func persist() {
        let recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        resolvedCache = resolvedCache.filter { recordsByID[$0.key] == $0.value.record }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
