import AppKit

@MainActor
final class UpdateCheckController {
    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    private static let lastCheckDateKey = "updates.lastCheckDate"

    var onStateChange: ((Bool) -> Void)?
    private(set) var isChecking = false {
        didSet { onStateChange?(isChecking) }
    }
    private let checker = UpdateChecker()
    private let preferences: PreferencesStore
    private let defaults = UserDefaults.standard
    private var checkTask: Task<Void, Never>?
    private var automaticCheckTimer: Timer?
    private var automaticChecksStarted = false
    private var isAutomaticCheckInProgress = false

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }

    func checkForUpdates() {
        checkForUpdates(automatically: false)
    }

    func startAutomaticChecks() {
        guard preferences.automaticUpdateChecksEnabled, !automaticChecksStarted else { return }
        automaticChecksStarted = true
        // Leave launch and initial Dock setup time to finish first.
        scheduleAutomaticCheck(minimumDelay: 10)
    }

    func stop() {
        stopAutomaticChecks()
        checkTask?.cancel()
    }

    func refreshAutomaticCheckPreference() {
        if preferences.automaticUpdateChecksEnabled {
            startAutomaticChecks()
        } else {
            stopAutomaticChecks()
        }
    }

    private func stopAutomaticChecks() {
        automaticChecksStarted = false
        automaticCheckTimer?.invalidate()
        automaticCheckTimer = nil
        if isAutomaticCheckInProgress { checkTask?.cancel() }
    }

    private func scheduleAutomaticCheck(minimumDelay: TimeInterval = 1) {
        guard automaticChecksStarted, preferences.automaticUpdateChecksEnabled else { return }
        automaticCheckTimer?.invalidate()
        let remaining: TimeInterval
        if let lastCheck = defaults.object(forKey: Self.lastCheckDateKey) as? Date {
            // A clock change should never postpone checking by more than a day.
            remaining = min(Self.automaticCheckInterval,
                            lastCheck.addingTimeInterval(Self.automaticCheckInterval).timeIntervalSinceNow)
        } else {
            remaining = 0
        }
        let delay = max(minimumDelay, remaining)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] firedTimer in
            Task { @MainActor [weak self] in
                guard let self, self.automaticChecksStarted,
                      self.automaticCheckTimer === firedTimer else { return }
                self.automaticCheckTimer = nil
                self.checkForUpdates(automatically: true)
            }
        }
        timer.tolerance = min(60, delay * 0.05)
        RunLoop.main.add(timer, forMode: .common)
        automaticCheckTimer = timer
    }

    private func checkForUpdates(automatically: Bool) {
        guard !isChecking else { return }
        if automatically {
            guard automaticChecksStarted, preferences.automaticUpdateChecksEnabled else { return }
        }
        isAutomaticCheckInProgress = automatically
        isChecking = true
        // Persist attempts, including offline failures, to avoid repeated
        // automatic requests after relaunch. Manual checks remain unrestricted.
        defaults.set(Date(), forKey: Self.lastCheckDateKey)
        scheduleAutomaticCheck()
        checkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isAutomaticCheckInProgress = false
                self.isChecking = false
                self.checkTask = nil
                // A result dialog can stay open past the next due time.
                self.scheduleAutomaticCheck()
            }
            do {
                let result = try await self.checker.check()
                guard !Task.isCancelled else { return }
                if automatically {
                    guard self.automaticChecksStarted, self.preferences.automaticUpdateChecksEnabled else { return }
                    if case .upToDate = result { return }
                }
                self.present(result)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !automatically else { return }
                self.presentFailure(error)
            }
        }
    }

    private func present(_ result: UpdateChecker.Result) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        switch result {
        case let .upToDate(currentVersion):
            alert.messageText = L10n.text("updates.current.title")
            alert.informativeText = L10n.format("updates.current.message", currentVersion)
            alert.addButton(withTitle: L10n.text("updates.dismiss"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        case let .available(version, currentVersion, releaseURL):
            alert.messageText = L10n.text("updates.available.title")
            alert.informativeText = L10n.format("updates.available.message", version, currentVersion)
            alert.addButton(withTitle: L10n.text("updates.openRelease"))
            alert.addButton(withTitle: L10n.text("updates.later"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                if !NSWorkspace.shared.open(releaseURL) {
                    presentFailure(messageKey: "updates.error.openRelease")
                }
            }
        }
    }

    private func presentFailure(_ error: Error) {
        let messageKey: String
        switch error {
        case UpdateChecker.CheckError.noRelease:
            messageKey = "updates.error.noRelease"
        case UpdateChecker.CheckError.rateLimited:
            messageKey = "updates.error.rateLimited"
        case UpdateChecker.CheckError.invalidVersion:
            messageKey = "updates.error.invalidVersion"
        case UpdateChecker.CheckError.invalidResponse:
            messageKey = "updates.error.invalidResponse"
        default:
            messageKey = "updates.error.connection"
        }
        presentFailure(messageKey: messageKey)
    }

    private func presentFailure(messageKey: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("updates.error.title")
        alert.informativeText = L10n.text(messageKey)
        alert.addButton(withTitle: L10n.text("updates.dismiss"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
