import AppKit

@MainActor
final class DisplayCoordinator {
    private let topologyProvider: DisplayTopologyProvider
    private let preferences: PreferencesStore
    private let mouseMonitor: MouseEdgeMonitor
    private let fullScreenMonitor: FullScreenDisplayMonitor
    private let inputCandidateMonitor: InputCandidateWindowMonitor
    private let iconProvider: ApplicationIconProvider
    private let onItemAction: (DockItem) -> Void
    private let onItemContextAction: (DockItem, DockItemContextAction) -> Void
    private let contextMenuStateProvider: (DockItem) -> DockItemContextMenuState
    private let onDropRequest: (DockDropRequest) -> Bool

    private var panels: [DisplayIdentity: DockPanelController] = [:]
    private var observers: [NSObjectProtocol] = []
    private var snapshot: DockSnapshot = .empty
    private var fullScreenDisplayIDs: Set<CGDirectDisplayID> = []
    private var inputCandidateOccludedDisplayIdentities: Set<DisplayIdentity> = []
    private(set) var displays: [DisplayDescriptor] = []
    private var itemAnimationsEnabled = false
    private var snapshotPreparationGeneration: UInt64 = 0
    private var isPreparingSnapshot = false
    private var pendingSnapshots: [PendingSnapshot] = []

    private struct PendingSnapshot {
        let snapshot: DockSnapshot
        let itemAnimationsEnabled: Bool
    }

    /// Called after the current display descriptors and panels are rebuilt.
    /// Consumers that derive policy from topology can therefore read a
    /// coherent snapshot instead of racing the screen-parameter notification.
    var onTopologyChange: (([DisplayDescriptor]) -> Void)?

    init(
        topologyProvider: DisplayTopologyProvider = DisplayTopologyProvider(),
        preferences: PreferencesStore,
        mouseMonitor: MouseEdgeMonitor? = nil,
        fullScreenMonitor: FullScreenDisplayMonitor? = nil,
        inputCandidateMonitor: InputCandidateWindowMonitor? = nil,
        iconProvider: ApplicationIconProvider = .shared,
        onItemAction: @escaping (DockItem) -> Void,
        onItemContextAction: @escaping (DockItem, DockItemContextAction) -> Void = { _, _ in },
        contextMenuStateProvider: @escaping (DockItem) -> DockItemContextMenuState = { _ in .unavailable },
        onDropRequest: @escaping (DockDropRequest) -> Bool = { _ in false }
    ) {
        self.topologyProvider = topologyProvider
        self.preferences = preferences
        self.mouseMonitor = mouseMonitor ?? MouseEdgeMonitor()
        self.fullScreenMonitor = fullScreenMonitor ?? FullScreenDisplayMonitor()
        self.inputCandidateMonitor = inputCandidateMonitor ?? InputCandidateWindowMonitor()
        self.iconProvider = iconProvider
        self.onItemAction = onItemAction
        self.onItemContextAction = onItemContextAction
        self.contextMenuStateProvider = contextMenuStateProvider
        self.onDropRequest = onDropRequest
    }

    func start() {
        guard observers.isEmpty else { return }
        fullScreenMonitor.onFullScreenDisplaysChange = { [weak self] displayIDs in
            guard let self else { return }
            self.fullScreenDisplayIDs = displayIDs
            self.applyFullScreenState()
        }
        fullScreenMonitor.start()
        inputCandidateMonitor.regionsProvider = { [weak self] in
            self?.inputCandidateAvoidanceRegions ?? []
        }
        inputCandidateMonitor.onOccludedDisplaysChange = { [weak self] identities in
            guard let self else { return }
            self.inputCandidateOccludedDisplayIdentities = identities
            self.applyInputCandidateAvoidance()
        }
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

        mouseMonitor.onSample = { [weak self] location, pressedButtons, now, isFileDrag in
            guard let self else { return }
            for panel in self.panels.values {
                panel.processMouse(
                    location: location,
                    pressedButtons: pressedButtons,
                    now: now,
                    isFileDrag: isFileDrag
                )
            }
        }
        rebuildPanels()
        inputCandidateMonitor.start()
        mouseMonitor.start()
    }

    func stop() {
        snapshotPreparationGeneration &+= 1
        pendingSnapshots.removeAll()
        isPreparingSnapshot = false
        mouseMonitor.stop()
        inputCandidateMonitor.stop()
        inputCandidateMonitor.regionsProvider = { [] }
        inputCandidateMonitor.onOccludedDisplaysChange = nil
        inputCandidateOccludedDisplayIdentities.removeAll()
        fullScreenMonitor.stop()
        fullScreenMonitor.onFullScreenDisplaysChange = nil
        fullScreenDisplayIDs.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        panels.values.forEach { $0.destroy() }
        panels.removeAll()
    }

    func apply(snapshot: DockSnapshot) {
        pendingSnapshots.append(PendingSnapshot(
            snapshot: snapshot,
            itemAnimationsEnabled: itemAnimationsEnabled
        ))
        prepareNextSnapshotIfNeeded()
    }

    private func prepareNextSnapshotIfNeeded() {
        guard !isPreparingSnapshot, let pending = pendingSnapshots.first else {
            return
        }
        isPreparingSnapshot = true
        snapshotPreparationGeneration &+= 1
        let generation = snapshotPreparationGeneration
        let applicationURLs = pending.snapshot.items.compactMap { item in
            item.kind.isApplication ? item.applicationURL : nil
        }
        iconProvider.prepareIcons(for: applicationURLs) { [weak self] preparedIcons in
            guard let self,
                  self.snapshotPreparationGeneration == generation else {
                return
            }
            guard !self.pendingSnapshots.isEmpty else {
                self.isPreparingSnapshot = false
                return
            }
            let prepared = self.pendingSnapshots.removeFirst()
            self.iconProvider.retainForDisplay(preparedIcons)
            self.snapshot = prepared.snapshot
            self.panels.values.forEach {
                $0.apply(
                    snapshot: prepared.snapshot,
                    itemAnimationsEnabled: prepared.itemAnimationsEnabled
                )
            }
            self.inputCandidateMonitor.refreshNow()
            self.isPreparingSnapshot = false
            self.prepareNextSnapshotIfNeeded()
        }
    }

    func setItemAnimationsEnabled(_ enabled: Bool) {
        itemAnimationsEnabled = enabled
    }

    var windowSnapRegions: [WindowEdgeSnapRegion] {
        panels.compactMap { identity, panel in
            guard let bodyFrame = panel.restingDockBodyFrameInScreen,
                  let descriptor = displays.first(where: { $0.identity == identity }) else {
                return nil
            }
            return WindowEdgeSnapRegion(
                displayIdentity: identity,
                frame: WindowEdgeSnapGeometryPolicy.accessibilityFrame(
                    forCocoaFrame: bodyFrame,
                    cocoaDisplayFrame: descriptor.frame,
                    accessibilityDisplayFrame: CGDisplayBounds(descriptor.displayID)
                )
            )
        }
    }

    private var inputCandidateAvoidanceRegions: [InputCandidateDockRegion] {
        panels.compactMap { identity, panel in
            guard let bodyFrame = panel.inputCandidateAvoidanceFrameInScreen,
                  let descriptor = displays.first(where: { $0.identity == identity }) else {
                return nil
            }
            return InputCandidateDockRegion(
                displayIdentity: identity,
                frame: WindowEdgeSnapGeometryPolicy.accessibilityFrame(
                    forCocoaFrame: bodyFrame,
                    cocoaDisplayFrame: descriptor.frame,
                    accessibilityDisplayFrame: CGDisplayBounds(descriptor.displayID)
                )
            )
        }
    }

    func rebuildPanels() {
        displays = topologyProvider.currentDisplays()
        fullScreenMonitor.updateDisplays(displays)
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
                    iconProvider: iconProvider,
                    onItemAction: onItemAction,
                    onItemContextAction: onItemContextAction,
                    contextMenuStateProvider: contextMenuStateProvider,
                    onDropRequest: onDropRequest
                )
                panels[display.identity] = panel
            }
            panel.updateDescriptor(display, allDisplays: displays)
            panel.setFullScreenActive(
                fullScreenDisplayIDs.contains(display.displayID)
            )
            panel.apply(
                snapshot: snapshot,
                itemAnimationsEnabled: itemAnimationsEnabled
            )
            panel.applyPreferences()
        }

        applyInputCandidateAvoidance()
        inputCandidateMonitor.refreshNow()

        onTopologyChange?(displays)
        NotificationCenter.default.post(name: .echoDockDisplayTopologyDidChange, object: self)
    }

    private func applyPreferences() {
        rebuildPanels()
    }

    private func applyFullScreenState() {
        let displayIDsByIdentity = Dictionary(
            uniqueKeysWithValues: displays.map { ($0.identity, $0.displayID) }
        )
        for (identity, panel) in panels {
            guard let displayID = displayIDsByIdentity[identity] else { continue }
            panel.setFullScreenActive(fullScreenDisplayIDs.contains(displayID))
        }
    }

    private func applyInputCandidateAvoidance() {
        for (identity, panel) in panels {
            panel.setInputCandidateOccluding(
                inputCandidateOccludedDisplayIdentities.contains(identity)
            )
        }
    }

}
