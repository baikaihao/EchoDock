import Foundation

struct TrashFileIdentity: Equatable, Sendable {
    let volume: UInt64
    let file: UInt64
    let creationDate: Date?

    static func read(at url: URL, fileManager: FileManager) throws -> TrashFileIdentity? {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let volume = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return TrashFileIdentity(
            volume: volume.uint64Value,
            file: file.uint64Value,
            creationDate: attributes[.creationDate] as? Date
        )
    }
}

struct TrashUndoFile: Equatable, Sendable {
    let originalURL: URL
    let trashURL: URL
    let identity: TrashFileIdentity?
}

struct TrashUndoTransaction: Equatable, Sendable {
    let files: [TrashUndoFile]
    let shortcutSnapshots: [DockShortcutRecycleSnapshot]
}

struct TrashUndoFailure: Equatable {
    enum Reason: Equatable {
        case missing
        case identityChanged
        case identityUnavailable
        case destinationExists
        case operationFailed(String)
    }

    let originalURL: URL
    let reason: Reason

    var message: String {
        let detail: String
        switch reason {
        case .missing: detail = L10n.text("fileUndo.error.missing")
        case .identityChanged: detail = L10n.text("fileUndo.error.identityChanged")
        case .identityUnavailable: detail = L10n.text("fileUndo.error.identityUnavailable")
        case .destinationExists: detail = L10n.text("fileUndo.error.destinationExists")
        case let .operationFailed(message): detail = message
        }
        return L10n.format("fileUndo.error.file", originalURL.lastPathComponent, detail)
    }
}

struct TrashUndoResult {
    let restoredFileCount: Int
    let failures: [TrashUndoFailure]
}

@MainActor
final class TrashUndoService {
    private let shortcutStore: DockFileShortcutStore
    private let fileManager: FileManager
    private var transactions: [TrashUndoTransaction] = []

    var canUndo: Bool { !transactions.isEmpty }

    init(shortcutStore: DockFileShortcutStore, fileManager: FileManager = .default) {
        self.shortcutStore = shortcutStore
        self.fileManager = fileManager
    }

    func removeAllTransactions() {
        transactions.removeAll()
    }

    func record(recycledURLs: [URL: URL], shortcutSnapshots: [DockShortcutRecycleSnapshot]) {
        let files = recycledURLs.map { originalURL, trashURL in
            TrashUndoFile(
                originalURL: originalURL.standardizedFileURL,
                trashURL: trashURL.standardizedFileURL,
                identity: try? TrashFileIdentity.read(at: trashURL, fileManager: fileManager)
            )
        }
        guard !files.isEmpty else { return }
        append(TrashUndoTransaction(files: files, shortcutSnapshots: shortcutSnapshots))
    }

    func recordShortcutRemoval(_ snapshots: [DockShortcutRecycleSnapshot]) {
        guard !snapshots.isEmpty else { return }
        append(TrashUndoTransaction(files: [], shortcutSnapshots: snapshots))
    }

    @discardableResult
    func undoLatestTransaction() -> TrashUndoResult {
        guard let transaction = transactions.popLast() else {
            return TrashUndoResult(restoredFileCount: 0, failures: [])
        }

        var restoredURLs: [URL: URL] = [:]
        var retryableFiles: [TrashUndoFile] = []
        var failures: [TrashUndoFailure] = []
        for file in transaction.files {
            do {
                // Attributes identify the directory entry itself, including
                // dangling symlinks that fileExists would consider missing.
                let currentIdentity = try TrashFileIdentity.read(at: file.trashURL, fileManager: fileManager)
                guard let expectedIdentity = file.identity, let currentIdentity else {
                    failures.append(TrashUndoFailure(originalURL: file.originalURL, reason: .identityUnavailable))
                    continue
                }
                guard currentIdentity == expectedIdentity else {
                    failures.append(TrashUndoFailure(originalURL: file.originalURL, reason: .identityChanged))
                    continue
                }
                if (try? fileManager.attributesOfItem(atPath: file.originalURL.path)) != nil {
                    failures.append(TrashUndoFailure(originalURL: file.originalURL, reason: .destinationExists))
                    continue
                }
                try fileManager.moveItem(at: file.trashURL, to: file.originalURL)
                restoredURLs[file.originalURL] = file.originalURL
            } catch {
                let cocoaError = error as NSError
                let isMissing = cocoaError.domain == NSCocoaErrorDomain
                    && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoaError.code)
                    && (try? fileManager.attributesOfItem(atPath: file.trashURL.path)) == nil
                let destinationExists = cocoaError.domain == NSCocoaErrorDomain
                    && cocoaError.code == NSFileWriteFileExistsError
                failures.append(TrashUndoFailure(
                    originalURL: file.originalURL,
                    reason: isMissing ? .missing
                        : destinationExists ? .destinationExists : .operationFailed(error.localizedDescription)
                ))
                if !isMissing && !destinationExists { retryableFiles.append(file) }
            }
        }

        let restoredSnapshots = transaction.files.isEmpty
            ? transaction.shortcutSnapshots
            : transaction.shortcutSnapshots.filter { restoredURLs[$0.originalURL.standardizedFileURL] != nil }
        if !restoredSnapshots.isEmpty {
            shortcutStore.restore(restoredSnapshots, restoredURLs: restoredURLs)
        }
        if !retryableFiles.isEmpty {
            let retryableURLs = Set(retryableFiles.map(\.originalURL))
            append(TrashUndoTransaction(
                files: retryableFiles,
                shortcutSnapshots: transaction.shortcutSnapshots.filter {
                    retryableURLs.contains($0.originalURL.standardizedFileURL)
                }
            ))
        }
        return TrashUndoResult(restoredFileCount: restoredURLs.count, failures: failures)
    }

    private func append(_ transaction: TrashUndoTransaction) {
        transactions.append(transaction)
        if transactions.count > 20 {
            transactions.removeFirst(transactions.count - 20)
        }
    }
}
