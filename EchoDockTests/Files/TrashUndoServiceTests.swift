import Foundation
import Testing
@testable import EchoDock

@MainActor
struct TrashUndoServiceTests {
    @Test
    func restoresTheRecordedFileWithoutAccessibilityPermission() throws {
        let fixture = try UndoFixture()
        let original = fixture.original("document.txt")
        let trash = try fixture.trashed("document.txt", contents: "original")
        fixture.service.record(recycledURLs: [original: trash], shortcutSnapshots: [])
        #expect(fixture.service.canUndo)

        let result = fixture.service.undoLatestTransaction()

        #expect(result.restoredFileCount == 1)
        #expect(result.failures.isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        #expect(!fixture.service.canUndo)
    }

    @Test
    func aReplacementAtTheSameTrashPathIsNeverRestored() throws {
        let fixture = try UndoFixture()
        let original = fixture.original("document.txt")
        let trash = try fixture.trashed("document.txt", contents: "original")
        fixture.service.record(recycledURLs: [original: trash], shortcutSnapshots: [])
        try FileManager.default.moveItem(at: trash, to: trash.appendingPathExtension("moved"))
        try "replacement".write(to: trash, atomically: true, encoding: .utf8)

        let result = fixture.service.undoLatestTransaction()

        #expect(result.failures.map(\.reason) == [.identityChanged])
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try String(contentsOf: trash, encoding: .utf8) == "replacement")
        #expect(!fixture.service.canUndo)
    }

    @Test(arguments: [false, true])
    func anOccupiedDestinationIsNotOverwritten(danglingSymlink: Bool) throws {
        let fixture = try UndoFixture()
        let original = fixture.original("document.txt")
        let trash = try fixture.trashed("document.txt", contents: "original")
        fixture.service.record(recycledURLs: [original: trash], shortcutSnapshots: [])
        if danglingSymlink {
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: fixture.root.appendingPathComponent("missing"))
        } else {
            try "new document".write(to: original, atomically: true, encoding: .utf8)
        }

        let result = fixture.service.undoLatestTransaction()

        #expect(result.failures.map(\.reason) == [.destinationExists])
        #expect(FileManager.default.fileExists(atPath: trash.path))
        #expect(!fixture.service.canUndo)
        if !danglingSymlink {
            #expect(try String(contentsOf: original, encoding: .utf8) == "new document")
        }
    }

    @Test
    func aMissingItemDoesNotBlockAnOlderUndo() throws {
        let fixture = try UndoFixture()
        let older = fixture.original("older.txt")
        let olderTrash = try fixture.trashed("older.txt", contents: "older")
        fixture.service.record(recycledURLs: [older: olderTrash], shortcutSnapshots: [])
        let missingTrash = try fixture.trashed("missing.txt", contents: "missing")
        fixture.service.record(recycledURLs: [fixture.original("missing.txt"): missingTrash], shortcutSnapshots: [])
        try FileManager.default.removeItem(at: missingTrash)

        let result = fixture.service.undoLatestTransaction()

        #expect(result.failures.map(\.reason) == [.missing])
        #expect(fixture.service.canUndo)
        #expect(fixture.service.undoLatestTransaction().restoredFileCount == 1)
        #expect(try String(contentsOf: older, encoding: .utf8) == "older")
    }

    @Test
    func anUnverifiedFileIsNotRestoredIfItAppearsLater() throws {
        let fixture = try UndoFixture()
        let trash = fixture.root.appendingPathComponent("trash/late.txt")
        fixture.service.record(recycledURLs: [fixture.original("late.txt"): trash], shortcutSnapshots: [])
        _ = try fixture.trashed("late.txt", contents: "new item")

        #expect(fixture.service.undoLatestTransaction().failures.map(\.reason) == [.identityUnavailable])
        #expect(FileManager.default.fileExists(atPath: trash.path))
        #expect(!fixture.service.canUndo)
    }

    @Test
    func aTemporaryDestinationFailureCanBeRetriedExplicitly() throws {
        let fixture = try UndoFixture()
        let parent = fixture.original("subfolder")
        let original = parent.appendingPathComponent("document.txt")
        let trash = try fixture.trashed("document.txt", contents: "original")
        fixture.service.record(recycledURLs: [original: trash], shortcutSnapshots: [])

        let first = fixture.service.undoLatestTransaction()
        #expect(first.failures.count == 1)
        #expect(fixture.service.canUndo)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let second = fixture.service.undoLatestTransaction()
        #expect(second.failures.isEmpty)
        #expect(second.restoredFileCount == 1)
        #expect(!fixture.service.canUndo)
    }

    @Test
    func aPartialRestoreOnlyRestoresShortcutsForSuccessfulFiles() throws {
        let fixture = try UndoFixture()
        let first = fixture.original("first.txt")
        let second = fixture.original("second.txt")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)
        fixture.store.insert(fileURLs: [first, second], at: 0)
        let ids = fixture.store.records.map(\.id)
        let snapshots = fixture.store.snapshots(for: ids)
        let firstTrash = fixture.root.appendingPathComponent("trash/first.txt")
        let secondTrash = fixture.root.appendingPathComponent("trash/second.txt")
        try FileManager.default.moveItem(at: first, to: firstTrash)
        try FileManager.default.moveItem(at: second, to: secondTrash)
        fixture.store.remove(shortcutIDs: ids)
        fixture.service.record(recycledURLs: [first: firstTrash, second: secondTrash], shortcutSnapshots: snapshots)
        try FileManager.default.removeItem(at: secondTrash)

        let result = fixture.service.undoLatestTransaction()

        #expect(result.restoredFileCount == 1)
        #expect(result.failures.map(\.reason) == [.missing])
        #expect(fixture.store.records.map(\.id) == [ids[0]])
        #expect(!fixture.service.canUndo)
    }

    @Test
    func shortcutOnlyUndoRestoresTheOriginalOrder() throws {
        let fixture = try UndoFixture()
        fixture.store.insert(fileURLs: [fixture.original("first"), fixture.original("second"), fixture.original("third")], at: 0)
        let ids = fixture.store.records.map(\.id)
        let snapshots = fixture.store.snapshots(for: [ids[0], ids[2]])
        fixture.store.remove(shortcutIDs: snapshots.map { $0.record.id })
        fixture.service.recordShortcutRemoval(snapshots)

        let result = fixture.service.undoLatestTransaction()

        #expect(result.failures.isEmpty)
        #expect(fixture.store.records.map(\.id) == ids)
        #expect(!fixture.service.canUndo)
    }
}

@MainActor
private final class UndoFixture {
    let root: URL
    let suite = "TrashUndoServiceTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: DockFileShortcutStore
    let service: TrashUndoService

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults = try #require(UserDefaults(suiteName: suite))
        store = DockFileShortcutStore(defaults: defaults)
        service = TrashUndoService(shortcutStore: store)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("original"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("trash"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }

    func original(_ name: String) -> URL { root.appendingPathComponent("original").appendingPathComponent(name) }

    func trashed(_ name: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent("trash").appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
