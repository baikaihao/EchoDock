import AppKit

@MainActor
final class DockPreferenceMonitor: NSObject {
    var onPossibleChange: (() -> Void)?

    private var timer: Timer?
    private var debounceWorkItem: DispatchWorkItem?
    private var distributedObserver: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }

        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.dock.prefchanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleDebouncedRefresh() }
        }

        let timer = Timer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(pollPreferences),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
        distributedObserver = nil
    }

    private func scheduleDebouncedRefresh() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.onPossibleChange?()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    @objc private func pollPreferences() {
        onPossibleChange?()
    }

    deinit {
        timer?.invalidate()
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
    }
}
