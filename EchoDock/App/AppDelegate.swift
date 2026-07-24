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
    private var appObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        NSApp.setActivationPolicy(.accessory)

        let iconProvider = ApplicationIconProvider.shared
        iconProvider.startObservingApplicationLaunches()
        let modelController = DockModelController(preferences: preferences)
        let nativeDockPolicyController = NativeDockPolicyController(preferences: preferences)
        let displayCoordinator = DisplayCoordinator(
            preferences: preferences,
            iconProvider: iconProvider,
            onItemAction: { [weak modelController] item in
                modelController?.performPrimaryAction(for: item)
            },
            onItemContextAction: { [weak modelController] item, action in
                modelController?.performContextAction(action, for: item)
            },
            contextMenuStateProvider: { [weak modelController] item in
                modelController?.contextMenuState(for: item) ?? .unavailable
            },
            onDropRequest: { [weak modelController] request in
                modelController?.handleDrop(request) ?? false
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

        observeAppActions()
        observeWorkspaceLifecycle()
        nativeDockPolicyController.start()
        displayCoordinator.start()
        modelController.start()
        displayCoordinator.apply(snapshot: modelController.snapshot)
        statusItemController.update(snapshot: modelController.snapshot)
        displayCoordinator.setItemAnimationsEnabled(true)
        ThirdSectionPermissionService().presentFirstRunNoticeIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        modelController?.stop()
        nativeDockPolicyController?.stop()
        displayCoordinator?.stop()
        ApplicationIconProvider.shared.stopObservingApplicationLaunches()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        appObservers.forEach(NotificationCenter.default.removeObserver)
        appObservers.removeAll()
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

    private func observeAppActions() {
        let center = NotificationCenter.default
        appObservers = [
            center.addObserver(
                forName: .echoDockOpenSettingsRequest,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.settingsWindowController?.show()
                }
            },
            center.addObserver(
                forName: .echoDockShowAboutRequest,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.statusItemController?.showAboutWindow()
                }
            },
            center.addObserver(
                forName: .echoDockQuitRequest,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
        ]
    }
}
