import AppKit

@MainActor
final class DockPreferenceMonitor: NSObject {
    var onPossibleChange: (() -> Void)?
    var onMetadataInvalidation: (() -> Void)?

    private var timer: Timer?
    private var debounceWorkItem: DispatchWorkItem?
    private var distributedObserver: NSObjectProtocol?
    private var metadataObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func start() {
        guard timer == nil else { return }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let volumeNotifications = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        for name in volumeNotifications {
            let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.onMetadataInvalidation?() }
            }
            metadataObservers.append((workspaceCenter, token))
        }
        let localeToken = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onMetadataInvalidation?() }
        }
        metadataObservers.append((.default, localeToken))

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
        timer.tolerance = 0.2
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
        metadataObservers.forEach { $0.center.removeObserver($0.token) }
        metadataObservers.removeAll()
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
        metadataObservers.forEach { $0.center.removeObserver($0.token) }
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
    }
}
