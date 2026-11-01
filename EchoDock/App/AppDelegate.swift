import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = PreferencesStore.shared
    private var modelController: DockModelController?
    private var displayCoordinator: DisplayCoordinator?
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var nativeDockPolicyController: NativeDockPolicyController?
    private var windowReservationService: WindowReservationService?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        NSApp.setActivationPolicy(.accessory)

        let iconProvider = ApplicationIconProvider.shared
        iconProvider.startObservingApplicationLaunches()
        let modelController = DockModelController(preferences: preferences)
        let fileUndoAction = FileUndoMenuAction(
            isAvailable: { [weak modelController] in modelController?.canUndoFileOperation ?? false },
            perform: { [weak modelController] in modelController?.undoLastFileOperation() }
        )
        modelController.onFileUndoFailure = { message in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.text("fileUndo.error.title")
            alert.informativeText = message
            alert.addButton(withTitle: L10n.text("fileUndo.error.dismiss"))
            alert.runModal()
        }
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
            },
            fileUndoAction: fileUndoAction
        )
        let windowReservationService = WindowReservationService(
            preferences: preferences,
            snapRegionsProvider: { [weak displayCoordinator] in
                displayCoordinator?.windowSnapRegions ?? []
            }
        )
        displayCoordinator.onTopologyChange = { [weak nativeDockPolicyController] _ in
            nativeDockPolicyController?.reconcile()
        }
        nativeDockPolicyController.onProtectedEdgePointerMotion = {
            [weak displayCoordinator] location, pressedButtons in
            displayCoordinator?.processMouse(
                location: location,
                pressedButtons: pressedButtons
            )
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
            },
            fileUndoAction: fileUndoAction
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
        self.windowReservationService = windowReservationService

        observeAppActions()
        observeWorkspaceLifecycle()
        nativeDockPolicyController.start()
        displayCoordinator.start()
        windowReservationService.start()
        modelController.start()
        displayCoordinator.apply(snapshot: modelController.snapshot)
        statusItemController.update(snapshot: modelController.snapshot)
        statusItemController.startAutomaticUpdateChecks()
        displayCoordinator.setItemAnimationsEnabled(true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.stopUpdateChecks()
        modelController?.stop()
        windowReservationService?.stop()
        nativeDockPolicyController?.stop()
        displayCoordinator?.stop()
        ApplicationIconProvider.shared.stopObservingApplicationLaunches()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        appObservers.forEach(NotificationCenter.default.removeObserver)
        appObservers.removeAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        windowReservationService?.stop {
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        if windowReservationService == nil { return .terminateNow }
        return .terminateLater
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
