import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let preferences: PreferencesStore
    private let onOpenSettings: () -> Void
    private let onRefresh: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: max(1, NSStatusBar.system.thickness - 2)
    )
    private let menu = NSMenu()
    private var snapshot: DockSnapshot = .empty
    private var preferencesObserver: NSObjectProtocol?
    private var aboutWindowController: AboutWindowController?

    init(
        preferences: PreferencesStore,
        onOpenSettings: @escaping () -> Void,
        onRefresh: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.onOpenSettings = onOpenSettings
        self.onRefresh = onRefresh
        super.init()
        configure()
        observePreferences()
    }

    deinit {
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
    }

    func update(snapshot: DockSnapshot) {
        self.snapshot = snapshot
        updateStatusImage()
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func configure() {
        if let button = statusItem.button {
            button.image = statusImage()
            button.image?.isTemplate = true
            button.toolTip = "EchoDock"
        }
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    private func observePreferences() {
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: .echoDockPreferencesDidChange,
            object: preferences,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPreferenceState()
            }
        }
    }

    private func refreshPreferenceState() {
        updateStatusImage()
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        // “隐藏/显示” describes the visible Dock panels directly; the menu bar
        // utility and synchronization remain active while the panels are hidden.
        let enabledTitle = preferences.isEnabled
            ? L10n.text("statusItem.hideEchoDock")
            : L10n.text("statusItem.showEchoDock")
        let enabledItem = NSMenuItem(title: enabledTitle, action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.image = NSImage(
            systemSymbolName: preferences.isEnabled ? "eye.slash.fill" : "eye.fill",
            accessibilityDescription: enabledTitle
        )
        menu.addItem(enabledItem)

        let statusItem = NSMenuItem(title: syncStatusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusItem.image = NSImage(
            systemSymbolName: syncStatusSymbol,
            accessibilityDescription: syncStatusTitle
        )
        menu.addItem(statusItem)

        menu.addItem(.separator())

        let refreshTitle = L10n.text("statusItem.refresh")
        let refreshItem = NSMenuItem(title: refreshTitle, action: #selector(refresh), keyEquivalent: "r")
        refreshItem.keyEquivalentModifierMask = [.command]
        refreshItem.target = self
        refreshItem.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: refreshTitle
        )
        menu.addItem(refreshItem)

        let settingsTitle = L10n.text("statusItem.settings")
        let settingsItem = NSMenuItem(
            title: settingsTitle,
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        settingsItem.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: settingsTitle
        )
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: L10n.text("statusItem.about"),
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: L10n.text("statusItem.quit"),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private var syncStatusTitle: String {
        switch snapshot.syncStatus {
        case .normal:
            return L10n.format("statusItem.syncCount", snapshot.items.count)
        case .cached:
            return L10n.text("statusItem.cachedApps")
        case let .unavailable(message):
            return message
        }
    }

    private var syncStatusSymbol: String {
        switch snapshot.syncStatus {
        case .normal:
            return "checkmark.circle"
        case .cached:
            return "clock.arrow.circlepath"
        case .unavailable:
            return "exclamationmark.triangle"
        }
    }

    private func statusImage() -> NSImage? {
        NSImage(
            systemSymbolName: "dock.rectangle",
            accessibilityDescription: "EchoDock"
        ) ?? NSImage(
            systemSymbolName: "rectangle.3.group",
            accessibilityDescription: "EchoDock"
        )
    }

    private func updateStatusImage() {
        guard let button = statusItem.button else { return }
        let image = statusImage()
        image?.isTemplate = true
        button.image = image
        button.alphaValue = preferences.isEnabled ? 1 : 0.5
    }

    @objc private func toggleEnabled() {
        preferences.isEnabled.toggle()
        refreshPreferenceState()
    }

    @objc private func refresh() {
        onRefresh()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.present()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
