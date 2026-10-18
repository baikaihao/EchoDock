import AppKit

@MainActor
final class DisplaysSettingsViewController: NSViewController {
    private let preferences: PreferencesStore
    private let displayCoordinator: DisplayCoordinator
    private let nativeDockPolicyController: NativeDockPolicyController
    private let accessibilityPermissionService: AccessibilityPermissionService

    private let strategyControl = NSSegmentedControl(
        labels: [
            L10n.text("settings.displays.strategy.systemManaged"),
            L10n.text("settings.displays.strategy.fixed")
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let statusImageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let displayMapView = DisplayMapView()
    private let rowsStack = FlippedStackView()
    private let rowsScrollView = NSScrollView()
    private let openSystemSettingsButton = NSButton(
        title: L10n.text("settings.displays.openDesktopDockSettings"),
        target: nil,
        action: nil
    )
    private var observers: [NSObjectProtocol] = []

    init(
        preferences: PreferencesStore,
        displayCoordinator: DisplayCoordinator,
        nativeDockPolicyController: NativeDockPolicyController,
        accessibilityPermissionService: AccessibilityPermissionService = AccessibilityPermissionService()
    ) {
        self.preferences = preferences
        self.displayCoordinator = displayCoordinator
        self.nativeDockPolicyController = nativeDockPolicyController
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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 580))
        configureControls()
        buildLayout()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if observers.isEmpty {
            observers.append(NotificationCenter.default.addObserver(
                forName: .echoDockDisplayTopologyDidChange,
                object: displayCoordinator,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .echoDockDisplayAssignmentsDidChange,
                object: preferences,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .echoDockNativeDockLockStatusDidChange,
                object: nil,
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

    override func viewDidLayout() {
        super.viewDidLayout()
        updateRowsFrame()
    }

    func refresh() {
        guard isViewLoaded else { return }
        nativeDockPolicyController.reconcile()

        let displays = displayCoordinator.displays
        let currentNativeDockIdentity = currentNativeDockIdentity(in: displays)
        strategyControl.selectedSegment = preferences.nativeDockStrategy == .systemManaged ? 0 : 1
        displayMapView.configure(
            displays: displays,
            nativeDockDisplay: currentNativeDockIdentity,
            echoDockEnabled: preferences.displayEnabledMap(for: displays)
        )
        rebuildDisplayRows(displays, currentNativeDockIdentity: currentNativeDockIdentity)
        updateStatus(displays)
    }

    private func configureControls() {
        strategyControl.target = self
        strategyControl.action = #selector(strategyChanged)
        strategyControl.segmentStyle = .rounded
        strategyControl.setWidth(156, forSegment: 0)
        strategyControl.setWidth(180, forSegment: 1)

        statusImageView.imageScaling = .scaleProportionallyUpOrDown
        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        statusImageView.widthAnchor.constraint(equalToConstant: 17).isActive = true
        statusImageView.heightAnchor.constraint(equalToConstant: 17).isActive = true
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .left
        statusLabel.maximumNumberOfLines = 2

        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 0

        openSystemSettingsButton.bezelStyle = .rounded
        openSystemSettingsButton.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: L10n.text("settings.displays.openSystemSettings")
        )
        openSystemSettingsButton.imagePosition = .imageLeading
        openSystemSettingsButton.target = self
        openSystemSettingsButton.action = #selector(openSystemSettings)
    }

    private func buildLayout() {
        let title = NSTextField(labelWithString: L10n.text("settings.displays.title"))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .left
        title.translatesAutoresizingMaskIntoConstraints = false

        let strategyLabel = NSTextField(labelWithString: L10n.text("settings.displays.nativeDock"))
        strategyLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        strategyLabel.alignment = .left

        let strategyRow = NSStackView(views: [strategyLabel, NSView(), strategyControl])
        strategyRow.orientation = .horizontal
        strategyRow.alignment = .centerY

        let statusRow = NSStackView(views: [statusImageView, statusLabel, NSView(), openSystemSettingsButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.detachesHiddenViews = true

        let columnHeader = makeColumnHeader()

        rowsScrollView.drawsBackground = false
        rowsScrollView.hasVerticalScroller = true
        rowsScrollView.autohidesScrollers = true
        rowsScrollView.documentView = rowsStack
        rowsScrollView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(
            views: [title, strategyRow, statusRow, displayMapView, columnHeader, rowsScrollView]
        )
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        stack.setCustomSpacing(22, after: title)
        stack.setCustomSpacing(18, after: statusRow)
        stack.setCustomSpacing(8, after: displayMapView)

        displayMapView.translatesAutoresizingMaskIntoConstraints = false
        displayMapView.heightAnchor.constraint(equalToConstant: 150).isActive = true
        columnHeader.heightAnchor.constraint(equalToConstant: 20).isActive = true
        rowsScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24)
        ])
    }

    private func makeColumnHeader() -> NSView {
        let displayLabel = NSTextField(labelWithString: L10n.text("settings.displays.displayColumn"))
        let nativeLabel = NSTextField(labelWithString: L10n.text("settings.displays.nativeDock"))
        let multiLabel = NSTextField(labelWithString: "EchoDock")
        [displayLabel, nativeLabel, multiLabel].forEach {
            $0.font = .systemFont(ofSize: 11, weight: .medium)
            $0.textColor = .tertiaryLabelColor
        }
        displayLabel.alignment = .left
        nativeLabel.alignment = .center
        multiLabel.alignment = .center

        let row = NSView()
        displayLabel.translatesAutoresizingMaskIntoConstraints = false
        nativeLabel.translatesAutoresizingMaskIntoConstraints = false
        multiLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(displayLabel)
        row.addSubview(nativeLabel)
        row.addSubview(multiLabel)
        NSLayoutConstraint.activate([
            displayLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            displayLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            nativeLabel.centerXAnchor.constraint(equalTo: row.trailingAnchor, constant: -132),
            nativeLabel.widthAnchor.constraint(equalToConstant: 90),
            multiLabel.centerXAnchor.constraint(equalTo: row.trailingAnchor, constant: -42),
            multiLabel.widthAnchor.constraint(equalToConstant: 80)
        ])
        return row
    }

    private func rebuildDisplayRows(
        _ displays: [DisplayDescriptor],
        currentNativeDockIdentity: DisplayIdentity?
    ) {
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if displays.isEmpty {
            let empty = NSTextField(labelWithString: L10n.text("settings.displays.empty"))
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            rowsStack.addArrangedSubview(empty)
            return
        }

        for display in displays {
            let row = DisplayAssignmentRowView()
            row.configure(
                display: display,
                containsNativeDock: currentNativeDockIdentity == display.identity,
                echoDockEnabled: preferences.isDisplayEnabled(display.identity),
                nativeSelectionEnabled: preferences.nativeDockStrategy == .fixedToSelectedDisplay
                    && !display.isMirrorSecondary
            )
            row.onSelectNativeDock = { [weak self] in
                self?.selectNativeDockTarget(display)
            }
            row.onToggleEchoDock = { [weak self] enabled in
                self?.setEchoDock(enabled, for: display)
            }
            rowsStack.addArrangedSubview(row)
            row.heightAnchor.constraint(equalToConstant: 52).isActive = true
        }
        updateRowsFrame()
    }

    private func updateRowsFrame() {
        guard isViewLoaded else { return }
        let width = max(1, rowsScrollView.contentSize.width)
        rowsStack.frame.size.width = width
        rowsStack.layoutSubtreeIfNeeded()
        rowsStack.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: max(rowsScrollView.contentSize.height, rowsStack.fittingSize.height)
        )
    }

    private func updateStatus(_ displays: [DisplayDescriptor]) {
        let strategy = preferences.nativeDockStrategy
        let target = preferences.nativeDockTarget.flatMap { identity in
            displays.first(where: { $0.identity == identity })
        }
        let currentNativeDockIdentity = currentNativeDockIdentity(in: displays)

        let symbol: String
        let text: String
        let showSettingsButton: Bool

        if strategy == .systemManaged {
            symbol = "info.circle"
            if let currentNativeDockIdentity,
               let currentDisplay = displays.first(where: { $0.identity == currentNativeDockIdentity }) {
                text = L10n.format(
                    "settings.displays.status.systemManagedCurrent",
                    currentDisplay.localizedName
                )
            } else if accessibilityPermissionService.isGranted {
                text = L10n.text("settings.displays.status.systemManagedDetectionUnavailable")
            } else {
                text = L10n.text("settings.displays.status.systemManagedPermissionRequired")
            }
            showSettingsButton = false
        } else if preferences.nativeDockTarget != nil, target == nil {
            symbol = "display.trianglebadge.exclamationmark"
            text = L10n.text("settings.displays.status.targetOffline")
            showSettingsButton = false
        } else if preferences.nativeDockTarget == nil {
            symbol = "exclamationmark.circle"
            text = L10n.text("settings.displays.status.selectTarget")
            showSettingsButton = false
        } else if let target, target.isMirrorSecondary {
            symbol = "display.trianglebadge.exclamationmark"
            text = L10n.text("settings.displays.status.mirrorNotEligible")
            showSettingsButton = false
        } else if let target, !target.isMain, !NSScreen.screensHaveSeparateSpaces {
            symbol = "person.2.badge.gearshape"
            text = L10n.text("settings.displays.status.separateSpacesRequired")
            showSettingsButton = true
        } else {
            showSettingsButton = false
            switch nativeDockPolicyController.nativeDockLockStatus {
            case .disabled:
                symbol = "clock"
                text = L10n.text("settings.displays.status.preparing")
            case .waitingForAccessibility:
                symbol = "hand.raised"
                text = L10n.text("settings.displays.status.accessibilityRequired")
            case .targetUnavailable:
                symbol = "display.trianglebadge.exclamationmark"
                text = L10n.text("settings.displays.status.targetOffline")
            case .relocating:
                symbol = "arrow.right.circle"
                text = target.map {
                    L10n.format("settings.displays.status.relocatingTo", $0.localizedName)
                } ?? L10n.text("settings.displays.status.relocating")
            case .active:
                if let target, currentNativeDockIdentity == target.identity {
                    symbol = "checkmark.circle"
                    text = L10n.format("settings.displays.status.fixedAt", target.localizedName)
                } else {
                    symbol = "clock"
                    text = L10n.text("settings.displays.status.verifying")
                }
            case .verificationFailed:
                symbol = "exclamationmark.triangle"
                text = L10n.text("settings.displays.status.verificationFailed")
            case .unavailable:
                symbol = "exclamationmark.triangle"
                text = L10n.text("settings.displays.status.unavailable")
            }
        }

        statusImageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        statusImageView.contentTintColor = .secondaryLabelColor
        statusLabel.stringValue = text
        openSystemSettingsButton.isHidden = !showSettingsButton
    }

    private func currentNativeDockIdentity(in displays: [DisplayDescriptor]) -> DisplayIdentity? {
        guard let displayID = nativeDockPolicyController.currentNativeDockDisplayID else {
            return nil
        }
        return displays.first(where: {
            $0.displayID == displayID && !$0.isMirrorSecondary
        })?.identity
    }

    @objc private func strategyChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            preferences.nativeDockStrategy = .systemManaged
            nativeDockPolicyController.reconcile()
            refresh()
            return
        }

        guard preferences.nativeDockStrategy != .fixedToSelectedDisplay else {
            refresh()
            return
        }

        let displays = displayCoordinator.displays
        let storedTarget = preferences.nativeDockTarget.flatMap { identity in
            displays.first(where: { $0.identity == identity && !$0.isMirrorSecondary })
        }
        let currentDockDisplay = nativeDockPolicyController.currentNativeDockDisplayID.flatMap { displayID in
            displays.first(where: { $0.displayID == displayID && !$0.isMirrorSecondary })
        }
        let target = storedTarget
            ?? currentDockDisplay
            ?? displays.first(where: { $0.isMain && !$0.isMirrorSecondary })
            ?? displays.first(where: { !$0.isMirrorSecondary })

        guard let target else {
            refresh()
            return
        }

        preferences.applyNativeDockTargetSelection(
            target: target.identity,
            displays: displays,
            resetDisplayAssignments: true
        )
        nativeDockPolicyController.reconcile()
        refresh()
    }

    private func selectNativeDockTarget(_ display: DisplayDescriptor) {
        guard !display.isMirrorSecondary else { return }

        let displays = displayCoordinator.displays
        guard let currentDisplay = displays.first(where: {
            $0.identity == display.identity && !$0.isMirrorSecondary
        }) else {
            refresh()
            return
        }

        preferences.applyNativeDockTargetSelection(
            target: currentDisplay.identity,
            displays: displays,
            resetDisplayAssignments: false
        )
        nativeDockPolicyController.reconcile()
        refresh()
    }

    private func setEchoDock(_ enabled: Bool, for display: DisplayDescriptor) {
        if enabled,
           preferences.nativeDockStrategy == .fixedToSelectedDisplay,
           preferences.nativeDockTarget == display.identity {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.text("settings.displays.overlapWarning.title")
            alert.informativeText = L10n.text("settings.displays.overlapWarning.message")
            alert.addButton(withTitle: L10n.text("settings.displays.overlapWarning.enable"))
            alert.addButton(withTitle: L10n.text("common.cancel"))
            let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard response == .alertFirstButtonReturn else {
                    self?.refresh()
                    return
                }
                self?.preferences.setDisplayEnabled(true, identity: display.identity)
                self?.refresh()
            }
            if let window = view.window {
                alert.beginSheetModal(for: window, completionHandler: apply)
            } else {
                apply(alert.runModal())
            }
            return
        }

        preferences.setDisplayEnabled(enabled, identity: display.identity)
        refresh()
    }

    @objc private func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Desktop-Settings.extension?MissionControl",
            "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
        ]
        for rawValue in urls {
            if let url = URL(string: rawValue), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

}

private final class DisplayAssignmentRowView: NSView {
    var onSelectNativeDock: (() -> Void)?
    var onToggleEchoDock: ((Bool) -> Void)?

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let nativeRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let echoDockSwitch = NSSwitch()
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        display: DisplayDescriptor,
        containsNativeDock: Bool,
        echoDockEnabled: Bool,
        nativeSelectionEnabled: Bool
    ) {
        iconView.image = NSImage(
            systemSymbolName: display.isBuiltIn ? "laptopcomputer" : "display",
            accessibilityDescription: display.localizedName
        )
        nameLabel.stringValue = display.localizedName
        var details: [String] = []
        if display.isMain { details.append(L10n.text("settings.displays.detail.main")) }
        if display.isBuiltIn { details.append(L10n.text("settings.displays.detail.builtIn")) }
        if display.isMirrorSecondary { details.append(L10n.text("settings.displays.detail.mirrored")) }
        detailLabel.stringValue = details.isEmpty
            ? L10n.text("settings.displays.detail.external")
            : details.joined(separator: " · ")
        nativeRadio.state = containsNativeDock ? .on : .off
        nativeRadio.isEnabled = nativeSelectionEnabled
        nativeRadio.setAccessibilityLabel(L10n.format(
            "settings.displays.accessibility.setNativeTarget",
            display.localizedName
        ))
        echoDockSwitch.state = echoDockEnabled ? .on : .off
        echoDockSwitch.isEnabled = !display.isMirrorSecondary
        echoDockSwitch.setAccessibilityLabel(L10n.format(
            "settings.displays.accessibility.showEchoDock",
            display.localizedName
        ))

        // Repeat the state in the row surface itself. This is easier to scan
        // than an unlabeled radio/switch column, especially on a small map.
        if containsNativeDock {
            layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.08).cgColor
        } else if echoDockEnabled {
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.07).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 9
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor

        nativeRadio.target = self
        nativeRadio.action = #selector(selectNative)
        echoDockSwitch.target = self
        echoDockSwitch.action = #selector(toggleEchoDock)
        separator.boxType = .separator

        [iconView, nameLabel, detailLabel, nativeRadio, echoDockSwitch, separator].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: nativeRadio.leadingAnchor, constant: -12),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            nativeRadio.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -132),
            nativeRadio.centerYAnchor.constraint(equalTo: centerYAnchor),
            echoDockSwitch.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -42),
            echoDockSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func selectNative() {
        onSelectNativeDock?()
    }

    @objc private func toggleEchoDock(_ sender: NSSwitch) {
        onToggleEchoDock?(sender.state == .on)
    }
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class DisplayMapView: NSView {
    private var displays: [DisplayDescriptor] = []
    private var nativeDockDisplay: DisplayIdentity?
    private var echoDockEnabled: [DisplayIdentity: Bool] = [:]

    override var isFlipped: Bool { false }

    func configure(
        displays: [DisplayDescriptor],
        nativeDockDisplay: DisplayIdentity?,
        echoDockEnabled: [DisplayIdentity: Bool]
    ) {
        self.displays = displays.filter { !$0.isMirrorSecondary }
        self.nativeDockDisplay = nativeDockDisplay
        self.echoDockEnabled = echoDockEnabled
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !displays.isEmpty else { return }

        let unionFrame = displays.dropFirst().reduce(displays[0].frame) { $0.union($1.frame) }
        guard unionFrame.width > 0, unionFrame.height > 0 else { return }
        let contentBounds = bounds.insetBy(dx: 18, dy: 12)
        let scale = min(contentBounds.width / unionFrame.width, contentBounds.height / unionFrame.height)
        let scaledSize = NSSize(width: unionFrame.width * scale, height: unionFrame.height * scale)
        let offset = NSPoint(
            x: contentBounds.midX - scaledSize.width / 2,
            y: contentBounds.midY - scaledSize.height / 2
        )

        for display in displays {
            let rect = NSRect(
                x: offset.x + (display.frame.minX - unionFrame.minX) * scale,
                y: offset.y + (display.frame.minY - unionFrame.minY) * scale,
                width: max(56, display.frame.width * scale),
                height: max(38, display.frame.height * scale)
            )
            drawDisplay(display, in: rect)
        }
    }

    private func drawDisplay(_ display: DisplayDescriptor, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        let containsNativeDock = display.identity == nativeDockDisplay
        let hasEchoDock = echoDockEnabled[display.identity] == true

        // Tint the map itself so each assignment is readable without relying
        // on a thin status line whose meaning is easy to miss.
        let fillColor: NSColor = hasEchoDock
            ? NSColor.systemBlue.withAlphaComponent(0.11)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.92)
        fillColor.setFill()
        path.fill()

        (containsNativeDock ? NSColor.systemOrange : NSColor.separatorColor).setStroke()
        path.lineWidth = containsNativeDock ? 2 : 1
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let titleRect = rect.insetBy(dx: 6, dy: max(8, rect.height / 2 - 8))
        display.localizedName.draw(in: titleRect, withAttributes: attributes)

        // Explicit assignment badges make the map self-explanatory. Keep the
        // compact dot fallback for very small display rectangles.
        var badges: [(String, NSColor)] = []
        if containsNativeDock {
            badges.append((L10n.text("settings.displays.nativeDock"), .systemOrange))
        }
        if hasEchoDock { badges.append(("EchoDock", .systemBlue)) }
        if display.isMain {
            badges.append((L10n.text("settings.displays.badge.main"), .systemIndigo))
        }

        if rect.width >= 110 {
            var cursorX = rect.minX + 8
            let badgeY = rect.maxY - 20
            for (label, color) in badges.prefix(2) {
                let textSize = (label as NSString).size(withAttributes: [
                    .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold)
                ])
                let badgeWidth = textSize.width + 16
                let badgeRect = NSRect(x: cursorX, y: badgeY, width: badgeWidth, height: 15)
                let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 7.5, yRadius: 7.5)
                color.withAlphaComponent(0.16).setFill()
                badgePath.fill()
                color.setStroke()
                badgePath.lineWidth = 0.7
                badgePath.stroke()
                let badgeAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
                    .foregroundColor: color
                ]
                (label as NSString).draw(
                    in: NSRect(x: badgeRect.minX + 8, y: badgeRect.minY + 2.5, width: textSize.width, height: textSize.height),
                    withAttributes: badgeAttributes
                )
                cursorX += badgeWidth + 5
            }
        } else if !badges.isEmpty {
            let dot = NSBezierPath(ovalIn: NSRect(x: rect.maxX - 13, y: rect.maxY - 15, width: 7, height: 7))
            (badges.first?.1 ?? NSColor.systemBlue).setFill()
            dot.fill()
        }
    }
}
