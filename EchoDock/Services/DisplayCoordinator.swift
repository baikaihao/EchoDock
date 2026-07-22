import AppKit

@MainActor
final class DisplayCoordinator {
    private let topologyProvider: DisplayTopologyProvider
    private let preferences: PreferencesStore
    private let mouseMonitor: MouseEdgeMonitor
    private let onItemAction: (DockItem) -> Void
    private let onItemContextAction: (DockItem, DockItemContextAction) -> Void
    private let contextMenuStateProvider: (DockItem) -> DockItemContextMenuState

    private var panels: [DisplayIdentity: DockPanelController] = [:]
    private var observers: [NSObjectProtocol] = []
    private var snapshot: DockSnapshot = .empty
    private(set) var displays: [DisplayDescriptor] = []
    private var itemAnimationsEnabled = false

    /// Called after the current display descriptors and panels are rebuilt.
    /// Consumers that derive policy from topology can therefore read a
    /// coherent snapshot instead of racing the screen-parameter notification.
    var onTopologyChange: (([DisplayDescriptor]) -> Void)?

    init(
        topologyProvider: DisplayTopologyProvider = DisplayTopologyProvider(),
        preferences: PreferencesStore,
        mouseMonitor: MouseEdgeMonitor? = nil,
        onItemAction: @escaping (DockItem) -> Void,
        onItemContextAction: @escaping (DockItem, DockItemContextAction) -> Void = { _, _ in },
        contextMenuStateProvider: @escaping (DockItem) -> DockItemContextMenuState = { _ in .unavailable }
    ) {
        self.topologyProvider = topologyProvider
        self.preferences = preferences
        self.mouseMonitor = mouseMonitor ?? MouseEdgeMonitor()
        self.onItemAction = onItemAction
        self.onItemContextAction = onItemContextAction
        self.contextMenuStateProvider = contextMenuStateProvider
    }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildPanels() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .echoDockPreferencesDidChange,
            object: preferences,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyPreferences() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .echoDockDisplayAssignmentsDidChange,
            object: preferences,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildPanels() }
        })

        mouseMonitor.onSample = { [weak self] location, pressedButtons, now in
            guard let self else { return }
            for panel in self.panels.values {
                panel.processMouse(location: location, pressedButtons: pressedButtons, now: now)
            }
        }
        mouseMonitor.needsImmediateMovementSample = { [weak self] in
            self?.panels.values.contains(where: \.needsImmediatePointerSample) == true
        }
        rebuildPanels()
        mouseMonitor.start()
    }

    func stop() {
        mouseMonitor.stop()
        mouseMonitor.needsImmediateMovementSample = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        panels.values.forEach { $0.destroy() }
        panels.removeAll()
    }

    func apply(snapshot: DockSnapshot) {
        self.snapshot = snapshot
        panels.values.forEach {
            $0.apply(
                snapshot: snapshot,
                itemAnimationsEnabled: itemAnimationsEnabled
            )
        }
    }

    func setItemAnimationsEnabled(_ enabled: Bool) {
        itemAnimationsEnabled = enabled
    }

    func rebuildPanels() {
        displays = topologyProvider.currentDisplays()
        preferences.registerDisplays(displays)

        let eligible = displays.filter {
            !$0.isMirrorSecondary
                && preferences.isEnabled
                && preferences.isDisplayEnabled($0.identity)
        }
        let eligibleIdentities = Set(eligible.map(\.identity))

        let identitiesToRemove = panels.keys.filter { !eligibleIdentities.contains($0) }
        for identity in identitiesToRemove {
            panels.removeValue(forKey: identity)?.destroy()
        }

        for display in eligible {
            let panel: DockPanelController
            if let existing = panels[display.identity] {
                panel = existing
            } else {
                panel = DockPanelController(
                    descriptor: display,
                    preferences: preferences,
                    onItemAction: onItemAction,
                    onItemContextAction: onItemContextAction,
                    contextMenuStateProvider: contextMenuStateProvider
                )
                panels[display.identity] = panel
            }
            panel.updateDescriptor(display, allDisplays: displays)
            panel.apply(
                snapshot: snapshot,
                itemAnimationsEnabled: itemAnimationsEnabled
            )
            panel.applyPreferences()
        }

        onTopologyChange?(displays)
        NotificationCenter.default.post(name: .echoDockDisplayTopologyDidChange, object: self)
    }

    private func applyPreferences() {
        rebuildPanels()
    }
}
