import AppKit

@MainActor
final class AppearanceSettingsViewController: NSViewController {
    private static let backgroundStyleOptions: [(
        style: DockBackgroundStyle,
        localizationKey: String
    )] = [
        (.classic, "settings.appearance.backgroundStyle.classic"),
        (.liquidGlass, "settings.appearance.backgroundStyle.liquidGlass"),
        (.ice, "settings.appearance.backgroundStyle.ice")
    ]

    private let preferences: PreferencesStore
    private let supportsBackgroundStyleSelection: Bool

    private let iconSizeSlider = NSSlider()
    private let iconSizeValue = NSTextField(labelWithString: "")
    private let iconSpacingSlider = NSSlider()
    private let iconSpacingValue = NSTextField(labelWithString: "")
    private let transparencySlider = NSSlider()
    private let transparencyValue = NSTextField(labelWithString: "")
    private let backgroundBlurSlider = NSSlider()
    private let backgroundBlurValue = NSTextField(labelWithString: "")
    private let backgroundStyleControl = NSSegmentedControl()
    private let magnificationSwitch = NSSwitch()
    private let magnificationScaleSlider = NSSlider()
    private let magnificationScaleValue = NSTextField(labelWithString: "")
    private let magnificationRangeSlider = NSSlider()
    private let magnificationRangeValue = NSTextField(labelWithString: "")
    private let tooltipGapSlider = NSSlider()
    private let tooltipGapValue = NSTextField(labelWithString: "")
    private let launchBounceSwitch = NSSwitch()
    private let runningIndicatorsSwitch = NSSwitch()
    private let restoreDefaultsButton = NSButton(
        title: L10n.text("settings.appearance.restoreDefaults"),
        target: nil,
        action: nil
    )
    private var preferencesObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?

    init(
        preferences: PreferencesStore,
        supportsBackgroundStyleSelection: Bool = DockBackgroundStyleAvailability.isSupported
    ) {
        self.preferences = preferences
        self.supportsBackgroundStyleSelection = supportsBackgroundStyleSelection
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 520))
        configureControls()
        buildLayout()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if preferencesObserver == nil {
            preferencesObserver = NotificationCenter.default.addObserver(
                forName: .echoDockPreferencesDidChange,
                object: preferences,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        if accessibilityObserver == nil {
            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        iconSizeSlider.doubleValue = Double(preferences.iconSize)
        iconSizeValue.stringValue = L10n.format("format.points.oneDecimal", preferences.iconSize)
        iconSpacingSlider.doubleValue = Double(preferences.iconSpacing)
        iconSpacingValue.stringValue = L10n.format("format.points.oneDecimal", preferences.iconSpacing)
        transparencySlider.doubleValue = Double(preferences.dockTransparency)
        transparencyValue.stringValue = L10n.format(
            "format.percent.zeroDecimals",
            preferences.dockTransparency * 100
        )
        backgroundBlurSlider.doubleValue = Double(preferences.dockBackgroundBlur)
        backgroundBlurValue.stringValue = L10n.format(
            "format.percent.zeroDecimals",
            preferences.dockBackgroundBlur * 100
        )
        backgroundStyleControl.selectedSegment = Self.backgroundStyleOptions
            .firstIndex { $0.style == preferences.dockBackgroundStyle } ?? 0
        let allowsTransparencyTuning = DockBackgroundTuningPolicy.allowsTransparencyTuning(
            supportsLiquidGlass: supportsBackgroundStyleSelection,
            selectedStyle: preferences.dockBackgroundStyle,
            reduceTransparency: NSWorkspace.shared
                .accessibilityDisplayShouldReduceTransparency
        )
        transparencySlider.isEnabled = allowsTransparencyTuning
        backgroundBlurSlider.isEnabled = DockBackgroundTuningPolicy
            .allowsBackgroundBlurTuning(
                supportsLiquidGlass: supportsBackgroundStyleSelection,
                selectedStyle: preferences.dockBackgroundStyle,
                reduceTransparency: NSWorkspace.shared
                    .accessibilityDisplayShouldReduceTransparency
            )
        magnificationSwitch.state = preferences.magnificationEnabled ? .on : .off
        magnificationScaleSlider.doubleValue = Double(preferences.magnificationScale)
        magnificationScaleValue.stringValue = L10n.format(
            "format.multiplier.twoDecimals",
            preferences.magnificationScale
        )
        magnificationRangeSlider.doubleValue = Double(preferences.magnificationRange)
        magnificationRangeValue.stringValue = L10n.format(
            "format.icons.oneDecimal",
            preferences.magnificationRange
        )
        tooltipGapSlider.doubleValue = Double(preferences.tooltipGap)
        tooltipGapValue.stringValue = L10n.format("format.points.oneDecimal", preferences.tooltipGap)
        launchBounceSwitch.state = preferences.launchBounceEnabled ? .on : .off
        runningIndicatorsSwitch.state = preferences.runningIndicatorsEnabled ? .on : .off
        magnificationScaleSlider.isEnabled = preferences.magnificationEnabled
        magnificationRangeSlider.isEnabled = preferences.magnificationEnabled
    }

    private func configureControls() {
        configureContinuousSlider(
            iconSizeSlider,
            minimum: 32,
            maximum: 64,
            action: #selector(iconSizeChanged)
        )
        configureContinuousSlider(
            iconSpacingSlider,
            minimum: 4,
            maximum: 28,
            action: #selector(iconSpacingChanged)
        )
        configureContinuousSlider(
            transparencySlider,
            minimum: Double(DockBackgroundTransparency.allowedRange.lowerBound),
            maximum: Double(DockBackgroundTransparency.allowedRange.upperBound),
            action: #selector(transparencyChanged)
        )
        configureContinuousSlider(
            backgroundBlurSlider,
            minimum: Double(DockBackgroundBlur.allowedRange.lowerBound),
            maximum: Double(DockBackgroundBlur.allowedRange.upperBound),
            action: #selector(backgroundBlurChanged)
        )

        backgroundStyleControl.segmentCount = Self.backgroundStyleOptions.count
        for (index, option) in Self.backgroundStyleOptions.enumerated() {
            backgroundStyleControl.setLabel(
                L10n.text(option.localizationKey),
                forSegment: index
            )
        }
        backgroundStyleControl.trackingMode = .selectOne
        backgroundStyleControl.segmentStyle = .rounded
        backgroundStyleControl.target = self
        backgroundStyleControl.action = #selector(backgroundStyleChanged)

        magnificationSwitch.target = self
        magnificationSwitch.action = #selector(magnificationChanged)
        launchBounceSwitch.target = self
        launchBounceSwitch.action = #selector(launchBounceChanged)
        runningIndicatorsSwitch.target = self
        runningIndicatorsSwitch.action = #selector(runningIndicatorsChanged)

        restoreDefaultsButton.bezelStyle = .rounded
        restoreDefaultsButton.image = NSImage(
            systemSymbolName: "arrow.counterclockwise",
            accessibilityDescription: restoreDefaultsButton.title
        )
        restoreDefaultsButton.imagePosition = .imageLeading
        restoreDefaultsButton.target = self
        restoreDefaultsButton.action = #selector(restoreDefaults)

        configureContinuousSlider(
            magnificationScaleSlider,
            minimum: 1.10,
            maximum: 1.80,
            action: #selector(magnificationScaleChanged)
        )
        configureContinuousSlider(
            magnificationRangeSlider,
            minimum: 1.25,
            maximum: 3.50,
            action: #selector(magnificationRangeChanged)
        )
        configureContinuousSlider(
            tooltipGapSlider,
            minimum: 0,
            maximum: 24,
            action: #selector(tooltipGapChanged)
        )
    }

    private func buildLayout() {
        let title = NSTextField(labelWithString: L10n.text("settings.appearance.title"))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .left

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let documentView = AppearanceSettingsDocumentView()
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
        stack.addArrangedSubview(makeSectionLabel(L10n.text("settings.appearance.section.sizeLayout")))
        stack.addArrangedSubview(makeSliderRow(
            title: L10n.text("settings.appearance.iconSize"),
            slider: iconSizeSlider,
            valueLabel: iconSizeValue
        ))
        stack.addArrangedSubview(makeSliderRow(
            title: L10n.text("settings.appearance.iconSpacing"),
            slider: iconSpacingSlider,
            valueLabel: iconSpacingValue
        ))

        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeSectionLabel(L10n.text("settings.appearance.section.background")))
        if supportsBackgroundStyleSelection {
            stack.addArrangedSubview(makeRow(
                title: L10n.text("settings.appearance.backgroundStyle"),
                control: backgroundStyleControl
            ))
        }
        stack.addArrangedSubview(makeSliderRow(
            title: L10n.text("settings.appearance.backgroundTransparency"),
            slider: transparencySlider,
            valueLabel: transparencyValue
        ))
        if supportsBackgroundStyleSelection {
            stack.addArrangedSubview(makeSliderRow(
                title: L10n.text("settings.appearance.backgroundBlur"),
                slider: backgroundBlurSlider,
                valueLabel: backgroundBlurValue
            ))
        }

        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeSectionLabel(L10n.text("settings.appearance.section.interaction")))
        stack.addArrangedSubview(makeRow(
            title: L10n.text("settings.appearance.magnification"),
            control: magnificationSwitch
        ))
        stack.addArrangedSubview(makeSliderRow(
            title: L10n.text("settings.appearance.magnificationScale"),
            slider: magnificationScaleSlider,
            valueLabel: magnificationScaleValue
        ))
        stack.addArrangedSubview(makeSliderRow(
            title: L10n.text("settings.appearance.magnificationRange"),
            slider: magnificationRangeSlider,
            valueLabel: magnificationRangeValue
        ))
        stack.addArrangedSubview(makeSliderRow(
            title: L10n.text("settings.appearance.tooltipGap"),
            slider: tooltipGapSlider,
            valueLabel: tooltipGapValue
        ))

        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeSectionLabel(L10n.text("settings.appearance.section.effects")))
        stack.addArrangedSubview(makeRow(
            title: L10n.text("settings.appearance.launchBounce"),
            control: launchBounceSwitch
        ))
        stack.addArrangedSubview(makeRow(
            title: L10n.text("settings.appearance.runningIndicators"),
            control: runningIndicatorsSwitch
        ))

        stack.addArrangedSubview(makeSeparator())
        let restoreRow = NSStackView(views: [NSView(), restoreDefaultsButton])
        restoreRow.orientation = .horizontal
        restoreRow.alignment = .centerY
        stack.addArrangedSubview(restoreRow)

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

    private func configureContinuousSlider(
        _ slider: NSSlider,
        minimum: Double,
        maximum: Double,
        action: Selector
    ) {
        slider.minValue = minimum
        slider.maxValue = maximum
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.target = self
        slider.action = action
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        return label
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func makeRow(title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .left
        let row = NSStackView(views: [label, NSView(), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true
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

    @objc private func iconSizeChanged(_ sender: NSSlider) {
        preferences.iconSize = CGFloat(sender.doubleValue)
    }

    @objc private func iconSpacingChanged(_ sender: NSSlider) {
        preferences.iconSpacing = CGFloat(sender.doubleValue)
    }

    @objc private func transparencyChanged(_ sender: NSSlider) {
        preferences.dockTransparency = CGFloat(sender.doubleValue)
    }

    @objc private func backgroundBlurChanged(_ sender: NSSlider) {
        preferences.dockBackgroundBlur = CGFloat(sender.doubleValue)
    }

    @objc private func backgroundStyleChanged(_ sender: NSSegmentedControl) {
        guard Self.backgroundStyleOptions.indices.contains(sender.selectedSegment) else {
            refresh()
            return
        }
        preferences.dockBackgroundStyle = Self.backgroundStyleOptions[
            sender.selectedSegment
        ].style
        refresh()
    }

    @objc private func magnificationChanged(_ sender: NSSwitch) {
        preferences.magnificationEnabled = sender.state == .on
    }

    @objc private func magnificationScaleChanged(_ sender: NSSlider) {
        preferences.magnificationScale = CGFloat(sender.doubleValue)
    }

    @objc private func magnificationRangeChanged(_ sender: NSSlider) {
        preferences.magnificationRange = CGFloat(sender.doubleValue)
    }

    @objc private func tooltipGapChanged(_ sender: NSSlider) {
        preferences.tooltipGap = CGFloat(sender.doubleValue)
    }

    @objc private func launchBounceChanged(_ sender: NSSwitch) {
        preferences.launchBounceEnabled = sender.state == .on
    }

    @objc private func runningIndicatorsChanged(_ sender: NSSwitch) {
        preferences.runningIndicatorsEnabled = sender.state == .on
    }

    @objc private func restoreDefaults() {
        preferences.restoreAppearanceDefaults()
    }
}

private final class AppearanceSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
