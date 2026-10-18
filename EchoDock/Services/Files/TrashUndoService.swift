import AppKit
import ApplicationServices
import Carbon.HIToolbox

struct TrashUndoFile: Equatable, Sendable {
    let originalURL: URL
    let trashURL: URL
    let resourceIdentifier: String?
}

struct TrashUndoTransaction: Equatable, Sendable {
    let files: [TrashUndoFile]
    let shortcutSnapshots: [DockShortcutRecycleSnapshot]
}

final class TrashUndoService {
    var onUndoCompletion: (() -> Void)?

    private let shortcutStore: DockFileShortcutStore
    private let permissionService: AccessibilityPermissionService
    private let stateLock = NSLock()
    private var transactions: [TrashUndoTransaction] = []
    private var hasPendingTransaction = false
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var permissionRetryTimer: Timer?

    init(
        shortcutStore: DockFileShortcutStore,
        permissionService: AccessibilityPermissionService = AccessibilityPermissionService()
    ) {
        self.shortcutStore = shortcutStore
        self.permissionService = permissionService
    }

    @MainActor
    func start() {
        installEventTapIfPossible()
        guard permissionRetryTimer == nil else { return }
        let timer = Timer(
            timeInterval: 2,
            target: self,
            selector: #selector(retryEventTap),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        permissionRetryTimer = timer
    }

    @MainActor
    func stop() {
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        tearDownEventTap()
        stateLock.withLock {
            transactions.removeAll()
            hasPendingTransaction = false
        }
    }

    @MainActor
    private func tearDownEventTap() {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        eventTapSource = nil
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        eventTap = nil
    }

    @MainActor
    func record(
        recycledURLs: [URL: URL],
        shortcutSnapshots: [DockShortcutRecycleSnapshot]
    ) {
        let files = recycledURLs.map { originalURL, trashURL in
            let identifier = try? trashURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
                .fileResourceIdentifier
                .map(String.init(describing:))
            return TrashUndoFile(
                originalURL: originalURL.standardizedFileURL,
                trashURL: trashURL.standardizedFileURL,
                resourceIdentifier: identifier ?? nil
            )
        }
        guard !files.isEmpty else { return }
        let transaction = TrashUndoTransaction(
            files: files,
            shortcutSnapshots: shortcutSnapshots
        )
        stateLock.withLock {
            transactions.append(transaction)
            if transactions.count > 20 {
                transactions.removeFirst(transactions.count - 20)
            }
            hasPendingTransaction = true
        }
    }

    @MainActor
    func recordShortcutRemoval(_ shortcutSnapshots: [DockShortcutRecycleSnapshot]) {
        guard !shortcutSnapshots.isEmpty else { return }
        let transaction = TrashUndoTransaction(
            files: [],
            shortcutSnapshots: shortcutSnapshots
        )
        stateLock.withLock {
            transactions.append(transaction)
            if transactions.count > 20 {
                transactions.removeFirst(transactions.count - 20)
            }
            hasPendingTransaction = true
        }
    }

    fileprivate func consumeCommandZIfPossible(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_Z) else {
            return false
        }

        let flags = event.flags
        guard flags.contains(.maskCommand),
              !flags.contains(.maskShift),
              !flags.contains(.maskAlternate),
              !flags.contains(.maskControl) else {
            return false
        }

        let shouldConsume = stateLock.withLock { () -> Bool in
            guard hasPendingTransaction, !transactions.isEmpty else { return false }
            hasPendingTransaction = false
            return true
        }
        guard shouldConsume else { return false }
        DispatchQueue.main.async { [weak self] in
            self?.undoLatestTransaction()
        }
        return true
    }

    @MainActor
    private func installEventTapIfPossible() {
        if let eventTap {
            let isHealthy = permissionService.isGranted
                && CFMachPortIsValid(eventTap)
                && CGEvent.tapIsEnabled(tap: eventTap)
            if isHealthy { return }
            tearDownEventTap()
        }

        guard permissionService.isGranted else { return }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: echoDockTrashUndoEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    @objc @MainActor
    private func retryEventTap() {
        installEventTapIfPossible()
    }

    @MainActor
    private func undoLatestTransaction() {
        guard let transaction = stateLock.withLock({ transactions.popLast() }) else {
            stateLock.withLock { hasPendingTransaction = false }
            return
        }

        var restoredURLs: [URL: URL] = [:]
        var failedFiles: [TrashUndoFile] = []
        for file in transaction.files.reversed() {
            do {
                guard FileManager.default.fileExists(atPath: file.trashURL.path),
                      !FileManager.default.fileExists(atPath: file.originalURL.path) else {
                    failedFiles.append(file)
                    continue
                }
                try FileManager.default.moveItem(
                    at: file.trashURL,
                    to: file.originalURL
                )
                restoredURLs[file.originalURL] = file.originalURL
            } catch {
                failedFiles.append(file)
            }
        }

        let restoredSnapshots = transaction.files.isEmpty
            ? transaction.shortcutSnapshots
            : transaction.shortcutSnapshots.filter { snapshot in
                restoredURLs[snapshot.originalURL.standardizedFileURL] != nil
            }
        if !restoredSnapshots.isEmpty {
            shortcutStore.restore(restoredSnapshots, restoredURLs: restoredURLs)
        }

        if !failedFiles.isEmpty {
            let failedPaths = Set(failedFiles.map { $0.originalURL.standardizedFileURL.path })
            let failedSnapshots = transaction.shortcutSnapshots.filter {
                failedPaths.contains($0.originalURL.standardizedFileURL.path)
            }
            stateLock.withLock {
                transactions.append(TrashUndoTransaction(
                    files: failedFiles,
                    shortcutSnapshots: failedSnapshots
                ))
                hasPendingTransaction = true
            }
            NSSound.beep()
        } else {
            stateLock.withLock { hasPendingTransaction = !transactions.isEmpty }
        }
        onUndoCompletion?()
    }
}

private func echoDockTrashUndoEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<TrashUndoService>.fromOpaque(userInfo).takeUnretainedValue()
    return service.consumeCommandZIfPossible(type: type, event: event)
        ? nil
        : Unmanaged.passUnretained(event)
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
