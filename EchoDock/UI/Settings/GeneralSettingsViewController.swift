import AppKit
import ServiceManagement

@MainActor
final class GeneralSettingsViewController: NSViewController {
    private let preferences: PreferencesStore
    private let accessibilityPermissionService: AccessibilityPermissionService

    private let enabledSwitch = NSSwitch()
    private let autoHideSwitch = NSSwitch()
    private let autoHideInFullScreenSwitch = NSSwitch()
    private let reserveSpaceForWindowsSwitch = NSSwitch()
    private let reserveSpaceForWindowsDescription = NSTextField(labelWithString: "")
    private let runningApplicationsSwitch = NSSwitch()
    private let newDisplaysSwitch = NSSwitch()
    private let hideDelaySlider = NSSlider()
    private let hideDelayValue = NSTextField(labelWithString: "")
    private let edgeDelaySlider = NSSlider()
    private let edgeDelayValue = NSTextField(labelWithString: "")
    private let loginItemSwitch = NSSwitch()
    private let loginItemStatus = NSTextField(labelWithString: "")
    private let accessibilityPermissionButton = NSButton(
        title: L10n.text("accessibility.request"),
        target: nil,
        action: nil
    )
    private var observers: [NSObjectProtocol] = []

    init(
        preferences: PreferencesStore,
        accessibilityPermissionService: AccessibilityPermissionService = AccessibilityPermissionService()
    ) {
        self.preferences = preferences
        self.accessibilityPermissionService = accessibilityPermissionService
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 520))
        configureControls()
        buildLayout()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if observers.isEmpty {
            observers.append(NotificationCenter.default.addObserver(
                forName: .echoDockPreferencesDidChange,
                object: preferences,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        enabledSwitch.state = preferences.isEnabled ? .on : .off
        autoHideSwitch.state = preferences.autoHide ? .on : .off
        autoHideInFullScreenSwitch.state = preferences.autoHideInFullScreen ? .on : .off
        reserveSpaceForWindowsSwitch.state = preferences.reserveSpaceForWindows ? .on : .off
        reserveSpaceForWindowsSwitch.isEnabled = !preferences.autoHide
        reserveSpaceForWindowsDescription.stringValue = L10n.text(
            preferences.autoHide
                ? "settings.general.reserveSpaceForWindows.autoHideHint"
                : "settings.general.reserveSpaceForWindows.description"
        )
        runningApplicationsSwitch.state = preferences.showRunningApplications ? .on : .off
        newDisplaysSwitch.state = preferences.newDisplaysEnabled ? .on : .off
        hideDelaySlider.doubleValue = preferences.hideDelay
        hideDelayValue.stringValue = L10n.format("format.seconds.oneDecimal", preferences.hideDelay)
        hideDelaySlider.isEnabled = preferences.autoHide
        edgeDelaySlider.doubleValue = preferences.internalEdgeDelay
        edgeDelayValue.stringValue = L10n.format(
            "format.seconds.oneDecimal",
            preferences.internalEdgeDelay
        )
        edgeDelaySlider.isEnabled = preferences.autoHide

        let loginStatus = SMAppService.mainApp.status
        loginItemSwitch.state = loginStatus == .enabled ? .on : .off
        switch loginStatus {
        case .requiresApproval:
            loginItemStatus.stringValue = L10n.text("settings.general.login.requiresApproval")
        default:
            loginItemStatus.stringValue = ""
        }
        updateAccessibilityPermissionButton()
    }

    private func configureControls() {
        enabledSwitch.target = self
        enabledSwitch.action = #selector(enabledChanged)
        autoHideSwitch.target = self
        autoHideSwitch.action = #selector(autoHideChanged)
        autoHideInFullScreenSwitch.target = self
        autoHideInFullScreenSwitch.action = #selector(autoHideInFullScreenChanged)
        reserveSpaceForWindowsSwitch.target = self
        reserveSpaceForWindowsSwitch.action = #selector(reserveSpaceForWindowsChanged)
        reserveSpaceForWindowsDescription.font = .systemFont(ofSize: 11)
        reserveSpaceForWindowsDescription.textColor = .secondaryLabelColor
        reserveSpaceForWindowsDescription.maximumNumberOfLines = 2
        reserveSpaceForWindowsDescription.lineBreakMode = .byWordWrapping
        runningApplicationsSwitch.target = self
        runningApplicationsSwitch.action = #selector(runningApplicationsChanged)
        newDisplaysSwitch.target = self
        newDisplaysSwitch.action = #selector(newDisplaysChanged)

        hideDelaySlider.minValue = 0.2
        hideDelaySlider.maxValue = 2.0
        hideDelaySlider.isContinuous = true
        hideDelaySlider.target = self
        hideDelaySlider.action = #selector(hideDelayChanged)

        edgeDelaySlider.minValue = 0
        edgeDelaySlider.maxValue = 0.5
        edgeDelaySlider.isContinuous = true
        edgeDelaySlider.target = self
        edgeDelaySlider.action = #selector(edgeDelayChanged)

        loginItemSwitch.target = self
        loginItemSwitch.action = #selector(loginItemChanged)
        loginItemStatus.font = .systemFont(ofSize: 11)
        loginItemStatus.textColor = .secondaryLabelColor

        accessibilityPermissionButton.bezelStyle = .rounded
        accessibilityPermissionButton.imagePosition = .imageLeading
        accessibilityPermissionButton.target = self
        accessibilityPermissionButton.action = #selector(requestAccessibilityPermission)
        updateAccessibilityPermissionButton()
    }

    private func buildLayout() {
        let title = NSTextField(labelWithString: L10n.text("settings.general.title"))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .left

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let documentView = GeneralSettingsDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        stack.addArrangedSubview(title)
        stack.setCustomSpacing(22, after: title)
        stack.addArrangedSubview(makeSectionLabel(L10n.text("settings.general.section.dock")))
        stack.addArrangedSubview(makeRow(
            title: L10n.text("settings.general.enabled"),
            control: enabledSwitch
        ))
        stack.addArrangedSubview(makeRow(
            title: L10n.text("settings.general.autoHide"),
            control: autoHideSwitch
        ))
        stack.addArrangedSubview(makeRow(
            title: L10n.text("settings.general.autoHideInFullScreen"),
            control: autoHideInFullScreenSwitch
        ))
        stack.addArrangedSubview(makeDescribedRow(
            title: L10n.text("settings.general.reserveSpaceForWindows"),
            description: reserveSpaceForWindowsDescription,
            control: reserveSpaceForWindowsSwitch
        ))
        stack.addArrangedSubview(makeRow(
            title: L10n.text("settings.general.showRunningApplications"),
            control: runningApplicationsSwitch
        ))
        stack.addArrangedSubview(makeRow(
            title: L10n.text("settings.general.newDisplaysEnabled"),
            control: newDisplaysSwitch
        ))
        stack.addArrangedSubview(makeSliderRow(
            title: L10n.text("settings.general.hideDelay"),
            slider: hideDelaySlider,
            valueLabel: hideDelayValue
        ))
        stack.addArrangedSubview(makeSliderRow(
            title: L10n.text("settings.general.internalEdgeDelay"),
            slider: edgeDelaySlider,
            valueLabel: edgeDelayValue
        ))

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: separator)

        stack.addArrangedSubview(makeSectionLabel(L10n.text("settings.general.section.startup")))
        let loginControl = NSStackView(views: [loginItemSwitch, loginItemStatus])
        loginControl.orientation = .horizontal
        loginControl.alignment = .centerY
        loginControl.spacing = 8
        stack.addArrangedSubview(makeRow(
            title: L10n.text("settings.general.launchAtLogin"),
            control: loginControl
        ))

        let permissionSeparator = NSBox()
        permissionSeparator.boxType = .separator
        permissionSeparator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(permissionSeparator)
        permissionSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: permissionSeparator)

        stack.addArrangedSubview(makeSectionLabel(L10n.text("settings.general.section.permissions")))
        stack.addArrangedSubview(makeRow(
            title: L10n.text("settings.general.accessibility"),
            control: accessibilityPermissionButton
        ))

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -28)
        ])
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        return label
    }

    private func makeRow(title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .left
        let spacer = NSView()
        let row = NSStackView(views: [label, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return row
    }

    private func makeDescribedRow(
        title: String,
        description: NSTextField,
        control: NSView
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .left

        let labels = NSStackView(views: [label, description])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let spacer = NSView()
        let row = NSStackView(views: [labels, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        return row
    }

    private func makeSliderRow(title: String, slider: NSSlider, valueLabel: NSTextField) -> NSView {
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 68).isActive = true
        let controls = NSStackView(views: [slider, valueLabel])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        return makeRow(title: title, control: controls)
    }

    private func updateAccessibilityPermissionButton() {
        let state = AccessibilityPermissionButtonState.make(
            isGranted: accessibilityPermissionService.isGranted
        )
        accessibilityPermissionButton.title = state.title
        accessibilityPermissionButton.image = NSImage(
            systemSymbolName: state.symbolName,
            accessibilityDescription: state.title
        )
        accessibilityPermissionButton.isEnabled = state.isEnabled
        accessibilityPermissionButton.isHidden = state.isHidden
    }

    @objc private func enabledChanged(_ sender: NSSwitch) {
        preferences.isEnabled = sender.state == .on
    }

    @objc private func autoHideChanged(_ sender: NSSwitch) {
        preferences.autoHide = sender.state == .on
    }

    @objc private func autoHideInFullScreenChanged(_ sender: NSSwitch) {
        preferences.autoHideInFullScreen = sender.state == .on
    }

    @objc private func reserveSpaceForWindowsChanged(_ sender: NSSwitch) {
        let isEnabled = sender.state == .on
        preferences.reserveSpaceForWindows = isEnabled
        if isEnabled {
            _ = accessibilityPermissionService.requestIfNeeded()
        }
        refresh()
    }

    @objc private func runningApplicationsChanged(_ sender: NSSwitch) {
        preferences.showRunningApplications = sender.state == .on
    }

    @objc private func newDisplaysChanged(_ sender: NSSwitch) {
        preferences.newDisplaysEnabled = sender.state == .on
    }

    @objc private func hideDelayChanged(_ sender: NSSlider) {
        preferences.hideDelay = (sender.doubleValue * 10).rounded() / 10
    }

    @objc private func edgeDelayChanged(_ sender: NSSlider) {
        preferences.internalEdgeDelay = (sender.doubleValue * 10).rounded() / 10
    }

    @objc private func loginItemChanged(_ sender: NSSwitch) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            refresh()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.text("settings.general.login.changeFailed")
            alert.informativeText = error.localizedDescription
            if let window = view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
        refresh()
    }

    @objc private func requestAccessibilityPermission() {
        _ = accessibilityPermissionService.requestIfNeeded()
        refresh()
    }
}

private final class GeneralSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
