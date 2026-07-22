import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = PreferencesStore.shared
    private var modelController: DockModelController?
    private var displayCoordinator: DisplayCoordinator?
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var nativeDockPolicyController: NativeDockPolicyController?
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        NSApp.setActivationPolicy(.accessory)

        let modelController = DockModelController(preferences: preferences)
        let nativeDockPolicyController = NativeDockPolicyController(preferences: preferences)
        let displayCoordinator = DisplayCoordinator(
            preferences: preferences,
            onItemAction: { [weak modelController] item in
                modelController?.performPrimaryAction(for: item)
            },
            onItemContextAction: { [weak modelController] item, action in
                modelController?.performContextAction(action, for: item)
            },
            contextMenuStateProvider: { [weak modelController] item in
                modelController?.contextMenuState(for: item) ?? .unavailable
            }
        )
        displayCoordinator.onTopologyChange = { [weak nativeDockPolicyController] _ in
            nativeDockPolicyController?.reconcile()
        }

        let settingsWindowController = SettingsWindowController(
            preferences: preferences,
            displayCoordinator: displayCoordinator,
            nativeDockPolicyController: nativeDockPolicyController
        )
        let statusItemController = StatusItemController(
            preferences: preferences,
            onOpenSettings: { [weak settingsWindowController] in
                settingsWindowController?.show()
            },
            onRefresh: { [weak modelController, weak displayCoordinator, weak nativeDockPolicyController] in
                modelController?.refresh()
                displayCoordinator?.rebuildPanels()
                nativeDockPolicyController?.reconcile()
            }
        )

        modelController.onSnapshotChange = { [weak displayCoordinator, weak statusItemController] snapshot in
            displayCoordinator?.apply(snapshot: snapshot)
            statusItemController?.update(snapshot: snapshot)
        }

        self.modelController = modelController
        self.displayCoordinator = displayCoordinator
        self.statusItemController = statusItemController
        self.settingsWindowController = settingsWindowController
        self.nativeDockPolicyController = nativeDockPolicyController

        observeWorkspaceLifecycle()
        nativeDockPolicyController.start()
        displayCoordinator.start()
        modelController.start()
        displayCoordinator.apply(snapshot: modelController.snapshot)
        statusItemController.update(snapshot: modelController.snapshot)
        displayCoordinator.setItemAnimationsEnabled(true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        modelController?.stop()
        nativeDockPolicyController?.stop()
        displayCoordinator?.stop()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func observeWorkspaceLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.modelController?.refresh()
                    self?.displayCoordinator?.rebuildPanels()
                }
            }
        }
    }
}
