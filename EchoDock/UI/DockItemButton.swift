import AppKit
import CoreImage

enum DockRunningIndicatorPresentationPolicy {
    static func isVisible(isRunning: Bool, isEnabled: Bool) -> Bool {
        isEnabled && isRunning
    }
}

enum DockPrimaryPressAction: Equatable {
    case continueTracking
    case activate
    case beginFileDrag
    case presentContextMenu
    case cancel
}

enum DockPrimaryPressPolicy {
    static let minimumPressDuration: TimeInterval = NSEvent.doubleClickInterval
    static let movementTolerance: CGFloat = 4
    static let primaryMouseButtonMask = 1

    static func contextMenuEventType(
        for sourceEventType: NSEvent.EventType
    ) -> NSEvent.EventType {
        sourceEventType == .leftMouseDown ? .leftMouseDown : .rightMouseDown
    }

    static func fileDragEventType(
        for sourceEventType: NSEvent.EventType
    ) -> NSEvent.EventType {
        sourceEventType == .mouseMoved ? .leftMouseDragged : sourceEventType
    }

    static func exceededMovementTolerance(
        from startPoint: NSPoint,
        to point: NSPoint
    ) -> Bool {
        hypot(point.x - startPoint.x, point.y - startPoint.y) >= movementTolerance
    }

    static func action(
        eventType: NSEvent.EventType?,
        elapsed: TimeInterval,
        movementToleranceExceeded: Bool,
        isPointerInside: Bool,
        supportsFileDrag: Bool
    ) -> DockPrimaryPressAction {
        if movementToleranceExceeded,
           supportsFileDrag,
           eventType == .leftMouseDragged || eventType == .mouseMoved {
            return .beginFileDrag
        }

        if !movementToleranceExceeded,
           isPointerInside,
           elapsed >= minimumPressDuration {
            return .presentContextMenu
        }

        if eventType == .leftMouseUp {
            return isPointerInside ? .activate : .cancel
        }
        return .continueTracking
    }
}

private enum DockTrashIconProvider {
    private static let emptyResourcePath = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/TrashIcon.icns"
    private static let fullResourcePath = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FullTrashIcon.icns"

    static func image(for trashURL: URL) -> NSImage? {
        let isFull = hasContents(at: trashURL)
        let appKitName = isFull ? "NSTrashFull" : "NSTrashEmpty"

        // These names are the AppKit-provided versions used by Finder/Dock.
        if let image = NSImage(named: NSImage.Name(appKitName)) {
            return image
        }

        // Keep the native CoreTypes artwork available on systems where the
        // AppKit name is not registered in the process image catalog.
        let resourcePath = isFull ? fullResourcePath : emptyResourcePath
        return NSImage(contentsOfFile: resourcePath)
    }

    private static func hasContents(at trashURL: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: trashURL,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in false }
        ) else {
            return false
        }
        return enumerator.nextObject() != nil
    }
}

struct DockContextMenuPlacement {
    static let iconGap: CGFloat = 8
    static let screenMargin: CGFloat = 8

    static func menuFrame(
        menuSize: NSSize,
        anchorFrame: NSRect,
        visibleScreenFrame: NSRect
    ) -> NSRect {
        let width = max(0, menuSize.width)
        let height = max(0, menuSize.height)
        let minimumX = visibleScreenFrame.minX + screenMargin
        let maximumX = visibleScreenFrame.maxX - screenMargin - width

        let centeredX = anchorFrame.midX - width / 2
        let originX: CGFloat
        if maximumX >= minimumX {
            originX = min(maximumX, max(minimumX, centeredX))
        } else {
            originX = visibleScreenFrame.midX - width / 2
        }

        let desiredY = anchorFrame.maxY + iconGap
        let minimumY = visibleScreenFrame.minY + screenMargin
        let maximumY = visibleScreenFrame.maxY - screenMargin - height
        let originY: CGFloat
        if maximumY >= minimumY {
            originY = min(maximumY, max(minimumY, desiredY))
        } else {
            // AppKit will scroll an over-tall menu. Keep its top aligned to
            // the current display instead of allowing it onto another screen.
            originY = visibleScreenFrame.maxY - screenMargin - height
        }

        return NSRect(x: originX, y: originY, width: width, height: height)
    }
}

final class DockItemButton: NSButton, NSDraggingSource {
    var onPress: ((DockItem) -> Void)?
    var onContextAction: ((DockItem, DockItemContextAction) -> Void)?
    var onContextMenuPresentationChange: ((DockItemButton, Bool) -> Void)?
    var contextMenuStateProvider: ((DockItem) -> DockItemContextMenuState)?
    var contextMenuPopup: (NSMenu, NSEvent, NSView) -> Void = { menu, event, view in
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private let iconLayer = CALayer()
    private let primaryPressOverlayLayer = CALayer()
    private let primaryPressMaskLayer = CALayer()
    private let runningIndicatorLayer = CALayer()
    private let failureIndicatorLayer = CALayer()
    private let failureIndicatorMaskLayer = CALayer()
    private(set) var item: DockItem?
    private var iconImage: NSImage?
    private var iconSize: CGFloat = 48
    private var magnification: CGFloat = 1
    private var presenceProgress: CGFloat = 1
    private var launchBounceOffset: CGFloat = 0
    private var visualSlotCenterOffsetX: CGFloat = 0
    private var visualSlotWidth: CGFloat?
    private var activeContextMenu: NSMenu?
    private var isContextMenuPresented = false
    private var isTrackingPrimaryPress = false
    private var isFileDragSessionActive = false
    private var isDropTargeted = false
    private var isPrimaryPressHighlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // NSButton's default title is literally "Button". The icon is the
        // complete control surface, so an empty title is intentional.
        title = ""
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = false
        target = self
        action = #selector(didPress)

        iconLayer.contentsGravity = .resizeAspect
        iconLayer.magnificationFilter = .linear
        iconLayer.minificationFilter = .trilinear
        primaryPressOverlayLayer.backgroundColor = NSColor.black
            .withAlphaComponent(0.48)
            .cgColor
        primaryPressOverlayLayer.isHidden = true
        primaryPressOverlayLayer.mask = primaryPressMaskLayer
        primaryPressMaskLayer.contentsGravity = .resizeAspect
        primaryPressMaskLayer.magnificationFilter = .linear
        primaryPressMaskLayer.minificationFilter = .trilinear
        iconLayer.addSublayer(primaryPressOverlayLayer)
        layer?.addSublayer(iconLayer)

        runningIndicatorLayer.backgroundColor = NSColor.secondaryLabelColor.cgColor
        runningIndicatorLayer.cornerRadius = 2
        layer?.addSublayer(runningIndicatorLayer)

        failureIndicatorLayer.backgroundColor = NSColor.systemRed.cgColor
        failureIndicatorLayer.mask = failureIndicatorMaskLayer
        failureIndicatorMaskLayer.contentsGravity = .resizeAspect
        failureIndicatorMaskLayer.contents = Self.cgImage(from: NSImage(
            systemSymbolName: "exclamationmark.circle.fill",
            accessibilityDescription: L10n.text("dock.action.failed")
        ))
        failureIndicatorLayer.isHidden = true
        layer?.addSublayer(failureIndicatorLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateIconContentsScale()
    }

    override func layout() {
        super.layout()
        updatePresentationLayers()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled,
              !isHidden,
              alphaValue > 0.000_1,
              containsInteractionPoint(point) else { return nil }
        // Image and status subviews are decorative. Returning the button keeps
        // clicks on the visible icon on its primary interaction path.
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func rightMouseDown(with event: NSEvent) {
        presentContextMenu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            presentContextMenu(for: event)
            return
        }

        setPrimaryPressHighlighted(true)
        defer { setPrimaryPressHighlighted(false) }
        trackPrimaryMouseDown(event)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        guard item?.kind.shortcutID != nil,
              !isTrackingPrimaryPress,
              !isFileDragSessionActive else { return }
        beginFileDrag(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item else { return nil }
        cancelContextMenu()
        let menu = makeContextMenu(for: item)
        activeContextMenu = menu
        return menu
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard activeContextMenu === menu else { return }
        setContextMenuPresented(true)
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        guard activeContextMenu === menu else { return }
        activeContextMenu = nil
        setContextMenuPresented(false)
    }

    func configure(
        item: DockItem,
        iconSize: CGFloat,
        iconProvider: ApplicationIconProvider,
        showsRunningIndicator: Bool = true
    ) {
        let canReuseCurrentImage = self.item?.identity == item.identity
            && self.item?.kind == item.kind
            && self.item?.applicationURL.standardizedFileURL
                == item.applicationURL.standardizedFileURL
            && iconImage != nil
        self.item = item
        self.iconSize = iconSize
        switch item.kind {
        case .application, .fileShortcut:
            if !canReuseCurrentImage {
                setIconImage(iconProvider.icon(
                    for: item.applicationURL,
                    size: iconSize
                ))
            }
        case .trash:
            setIconImage(DockTrashIconProvider.image(for: item.applicationURL))
        case .dropPlaceholder:
            setIconImage(nil)
        }
        // Use DockContentView's native-looking capsule instead of AppKit's
        // default tooltip, which can truncate names to "Xco…".
        toolTip = nil
        setAccessibilityLabel(item.displayName)
        runningIndicatorLayer.isHidden = !DockRunningIndicatorPresentationPolicy.isVisible(
            isRunning: item.isRunning,
            isEnabled: showsRunningIndicator
        )

        switch item.transientState {
        case .normal:
            failureIndicatorLayer.isHidden = true
        case .launching:
            failureIndicatorLayer.isHidden = true
        case .failed:
            failureIndicatorLayer.isHidden = false
        }
        if case let .fileShortcut(_, _, isAvailable) = item.kind, !isAvailable {
            failureIndicatorLayer.isHidden = false
        }
        if item.kind == .dropPlaceholder {
            runningIndicatorLayer.isHidden = true
            failureIndicatorLayer.isHidden = true
        }
        setDropTargeted(false)
        needsLayout = true
    }

    func setDropTargeted(_ targeted: Bool) {
        guard isDropTargeted != targeted else { return }
        isDropTargeted = targeted
        guard item?.kind == .trash else { return }
        if targeted {
            let filter = CIFilter(name: "CIColorControls")
            filter?.setValue(-0.34, forKey: kCIInputBrightnessKey)
            layer?.filters = filter.map { [$0] }
        } else {
            layer?.filters = nil
        }
    }

    func cancelContextMenu() {
        guard let menu = activeContextMenu else { return }
        menu.cancelTrackingWithoutAnimation()
        if activeContextMenu === menu {
            activeContextMenu = nil
            setContextMenuPresented(false)
        }
    }

    private func presentContextMenu(for sourceEvent: NSEvent) {
        guard let menu = menu(for: sourceEvent) else { return }
        let positionedEvent = contextMenuEvent(for: menu, sourceEvent: sourceEvent)
        setContextMenuPresented(true)
        defer {
            if activeContextMenu === menu {
                activeContextMenu = nil
                setContextMenuPresented(false)
            }
        }
        contextMenuPopup(menu, positionedEvent, self)
    }

    private func contextMenuEvent(for menu: NSMenu, sourceEvent: NSEvent) -> NSEvent {
        guard let window, let screen = window.screen else { return sourceEvent }
        menu.update()
        let iconFrameInWindow = convert(magnifiedIconFrame, to: nil)
        let iconFrameOnScreen = window.convertToScreen(iconFrameInWindow)
        let menuFrame = DockContextMenuPlacement.menuFrame(
            menuSize: menu.size,
            anchorFrame: iconFrameOnScreen,
            visibleScreenFrame: screen.visibleFrame
        )
        let topLeftInWindow = window.convertPoint(fromScreen: NSPoint(
            x: menuFrame.minX,
            y: menuFrame.maxY
        ))

        return NSEvent.mouseEvent(
            with: DockPrimaryPressPolicy.contextMenuEventType(
                for: sourceEvent.type
            ),
            location: topLeftInWindow,
            modifierFlags: sourceEvent.modifierFlags,
            timestamp: sourceEvent.timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: sourceEvent.eventNumber,
            clickCount: sourceEvent.clickCount,
            pressure: sourceEvent.pressure
        ) ?? sourceEvent
    }

    /// Applies the shared transition's current magnification. The strip owns
    /// the animation clock, so this method writes the model frame directly.
    func setMagnification(_ value: CGFloat) {
        setPresentation(
            magnification: value,
            presenceProgress: presenceProgress,
            launchBounceOffset: launchBounceOffset,
            visualSlotCenterOffsetX: visualSlotCenterOffsetX,
            visualSlotWidth: visualSlotWidth
        )
    }

    func setPresentation(
        magnification value: CGFloat,
        presenceProgress progress: CGFloat,
        launchBounceOffset bounceOffset: CGFloat = 0,
        visualSlotCenterOffsetX centerOffsetX: CGFloat = 0,
        visualSlotWidth slotWidth: CGFloat? = nil
    ) {
        let clampedMagnification = min(1.80, max(1, value))
        let clampedProgress = min(1, max(0, progress))
        let clampedBounceOffset = max(0, bounceOffset)
        let clampedSlotWidth = slotWidth.map { max(0, $0) }
        let magnificationChanged = abs(clampedMagnification - magnification) > 0.0001
        let presenceChanged = abs(clampedProgress - presenceProgress) > 0.0001
        let bounceChanged = abs(clampedBounceOffset - launchBounceOffset) > 0.0001
        let centerOffsetChanged = abs(centerOffsetX - visualSlotCenterOffsetX) > 0.0001
        let slotWidthChanged = Self.optionalCGFloatChanged(
            from: visualSlotWidth,
            to: clampedSlotWidth
        )
        if magnificationChanged {
            layer?.zPosition = clampedMagnification
        }
        magnification = clampedMagnification
        presenceProgress = clampedProgress
        launchBounceOffset = clampedBounceOffset
        visualSlotCenterOffsetX = centerOffsetX
        visualSlotWidth = clampedSlotWidth
        if abs(alphaValue - clampedProgress) > 0.0001 {
            alphaValue = clampedProgress
        }
        let targetFrame = magnifiedIconFrame
        guard magnificationChanged
                || presenceChanged
                || bounceChanged
                || centerOffsetChanged
                || slotWidthChanged
                || !NSEqualRects(iconLayerFrame, targetFrame) else { return }
        updatePresentationLayers()
    }

    private var visualSlotFrameInBounds: NSRect {
        let width = visualSlotWidth ?? bounds.width
        return NSRect(
            x: bounds.midX + visualSlotCenterOffsetX - width / 2,
            y: bounds.minY,
            width: width,
            height: bounds.height
        )
    }

    private var magnifiedIconFrame: NSRect {
        let fullSide = iconSize * magnification
        let side = fullSide * presenceProgress
        let baselineInset: CGFloat = 8
        let fullOriginY = isFlipped
            ? bounds.maxY - baselineInset - fullSide
            : bounds.minY + baselineInset
        let centeredOriginY = fullOriginY + (fullSide - side) / 2
        let originY = centeredOriginY + (isFlipped ? -launchBounceOffset : launchBounceOffset)
        return NSRect(
            x: visualSlotFrameInBounds.midX - side / 2,
            y: originY,
            width: side,
            height: side
        )
    }

    /// Keep the decoded icon texture stable and let Core Animation handle the
    /// per-frame scale. AppKit no longer has to resize and redraw an image view
    /// for every pointer sample.
    private func updatePresentationLayers() {
        let targetIconFrame = magnifiedIconFrame
        let baseSide = max(0.001, iconSize)
        let scale = max(0.000_1, targetIconFrame.width / baseSide)
        let targetIconBounds = NSRect(
            x: 0,
            y: 0,
            width: baseSide,
            height: baseSide
        )
        let targetIconPosition = NSPoint(
            x: targetIconFrame.midX,
            y: targetIconFrame.midY
        )
        let targetIconTransform = CGAffineTransform(scaleX: scale, y: scale)
        let targetIconHidden = iconImage == nil || targetIconFrame.width <= 0.000_1
        let targetOverlayPosition = NSPoint(
            x: targetIconBounds.midX,
            y: targetIconBounds.midY
        )

        let indicatorY = isFlipped ? bounds.maxY - 5 : bounds.minY + 1
        let targetIndicatorBounds = NSRect(x: 0, y: 0, width: 4, height: 4)
        let targetIndicatorPosition = NSPoint(
            x: visualSlotFrameInBounds.midX,
            y: indicatorY + 2
        )
        let badgeY = isFlipped
            ? targetIconFrame.minY + 2
            : targetIconFrame.maxY - 18
        let targetFailureBounds = NSRect(x: 0, y: 0, width: 16, height: 16)
        let targetFailurePosition = NSPoint(
            x: targetIconFrame.maxX - 10,
            y: badgeY + 8
        )
        let targetFailureMaskPosition = NSPoint(x: 8, y: 8)

        guard !NSEqualRects(iconLayer.bounds, targetIconBounds)
                || iconLayer.position != targetIconPosition
                || iconLayer.affineTransform() != targetIconTransform
                || iconLayer.isHidden != targetIconHidden
                || !NSEqualRects(primaryPressOverlayLayer.bounds, targetIconBounds)
                || primaryPressOverlayLayer.position != targetOverlayPosition
                || !NSEqualRects(primaryPressMaskLayer.bounds, targetIconBounds)
                || primaryPressMaskLayer.position != targetOverlayPosition
                || !NSEqualRects(runningIndicatorLayer.bounds, targetIndicatorBounds)
                || runningIndicatorLayer.position != targetIndicatorPosition
                || !NSEqualRects(failureIndicatorLayer.bounds, targetFailureBounds)
                || failureIndicatorLayer.position != targetFailurePosition
                || !NSEqualRects(failureIndicatorMaskLayer.bounds, targetFailureBounds)
                || failureIndicatorMaskLayer.position != targetFailureMaskPosition else { return }

        withoutImplicitLayerActions {
            iconLayer.bounds = targetIconBounds
            iconLayer.position = targetIconPosition
            iconLayer.setAffineTransform(targetIconTransform)
            iconLayer.isHidden = targetIconHidden
            primaryPressOverlayLayer.bounds = targetIconBounds
            primaryPressOverlayLayer.position = targetOverlayPosition
            primaryPressMaskLayer.bounds = targetIconBounds
            primaryPressMaskLayer.position = targetOverlayPosition
            runningIndicatorLayer.bounds = targetIndicatorBounds
            runningIndicatorLayer.position = targetIndicatorPosition
            failureIndicatorLayer.bounds = targetFailureBounds
            failureIndicatorLayer.position = targetFailurePosition
            failureIndicatorMaskLayer.bounds = targetFailureBounds
            failureIndicatorMaskLayer.position = targetFailureMaskPosition
        }
    }

    private func updateIconContentsScale() {
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        guard iconLayer.contentsScale != scale
                || primaryPressOverlayLayer.contentsScale != scale
                || primaryPressMaskLayer.contentsScale != scale
                || runningIndicatorLayer.contentsScale != scale
                || failureIndicatorLayer.contentsScale != scale
                || failureIndicatorMaskLayer.contentsScale != scale else { return }
        withoutImplicitLayerActions {
            iconLayer.contentsScale = scale
            primaryPressOverlayLayer.contentsScale = scale
            primaryPressMaskLayer.contentsScale = scale
            runningIndicatorLayer.contentsScale = scale
            failureIndicatorLayer.contentsScale = scale
            failureIndicatorMaskLayer.contentsScale = scale
        }
    }

    private var iconLayerFrame: NSRect {
        let side = iconLayer.bounds.width * iconLayer.affineTransform().a
        return NSRect(
            x: iconLayer.position.x - side / 2,
            y: iconLayer.position.y - side / 2,
            width: side,
            height: side
        )
    }

    private func setIconImage(_ image: NSImage?) {
        iconImage = image
        let contents = Self.cgImage(from: image)

        withoutImplicitLayerActions {
            iconLayer.contents = contents
            primaryPressMaskLayer.contents = contents
        }
        updateIconContentsScale()
        updatePresentationLayers()
    }

    private func setPrimaryPressHighlighted(_ highlighted: Bool) {
        guard isPrimaryPressHighlighted != highlighted else { return }
        isPrimaryPressHighlighted = highlighted
        withoutImplicitLayerActions {
            primaryPressOverlayLayer.isHidden = !highlighted
        }
    }

    func iconFrame(in view: NSView) -> NSRect {
        convert(magnifiedIconFrame, to: view)
    }

    func visualSlotFrame(in view: NSView) -> NSRect {
        convert(visualSlotFrameInBounds, to: view)
    }

    /// Keeps horizontal ownership stable while neighboring icons move, but
    /// excludes the invisible headroom above and below the rendered icon.
    func tooltipHoverFrame(in view: NSView) -> NSRect {
        let controlFrame = visualSlotFrame(in: view)
        let iconFrame = iconFrame(in: view)
        return NSRect(
            x: controlFrame.minX,
            y: iconFrame.minY,
            width: controlFrame.width,
            height: iconFrame.height
        )
    }

    func containsInteractionPoint(_ point: NSPoint) -> Bool {
        bounds.contains(point) || magnifiedIconFrame.contains(point)
    }

    private static func cgImage(from image: NSImage?) -> CGImage? {
        guard let image else { return nil }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        )
    }

    private static func optionalCGFloatChanged(
        from oldValue: CGFloat?,
        to newValue: CGFloat?
    ) -> Bool {
        switch (oldValue, newValue) {
        case let (oldValue?, newValue?):
            return abs(oldValue - newValue) > 0.0001
        case (nil, nil):
            return false
        default:
            return true
        }
    }

    private func withoutImplicitLayerActions(_ updates: () -> Void) {
        guard !CATransaction.disableActions() else {
            updates()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updates()
        CATransaction.commit()
    }

    @objc private func didPress() {
        guard let item else { return }
        onPress?(item)
    }

    private func makeContextMenu(for item: DockItem) -> NSMenu {
        let state = contextMenuStateProvider?(item) ?? .unavailable
        let model = DockItemContextMenuBuilder.make(for: item, state: state)
        let menu = NSMenu(title: item.displayName)
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) {
            menu.automaticallyInsertsWritingToolsItems = false
        }

        if !model.options.isEmpty {
            let optionsTitle = L10n.text("dock.menu.options")
            let optionsMenu = NSMenu(title: optionsTitle)
            optionsMenu.autoenablesItems = false
            model.options.forEach { optionsMenu.addItem(makeMenuItem($0, item: item)) }

            let optionsItem = NSMenuItem(title: optionsTitle, action: nil, keyEquivalent: "")
            optionsItem.submenu = optionsMenu
            menu.addItem(optionsItem)
        }

        if !model.options.isEmpty, !model.commands.isEmpty {
            menu.addItem(.separator())
        }
        model.commands.forEach { command in
            let menuItem = makeMenuItem(command, item: item)
            if command.action == .closeWindow,
               let notice = model.closeWindowNotice,
               #available(macOS 14.4, *) {
                menuItem.subtitle = notice
            }
            menu.addItem(menuItem)

            if command.action == .closeWindow,
               let notice = model.closeWindowNotice,
               #unavailable(macOS 14.4) {
                menu.addItem(makeMenuNoticeItem(notice))
            }
        }
        return menu
    }

    private func makeMenuNoticeItem(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: NSFont.smallSystemFontSize,
                    weight: .regular
                ),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        menuItem.indentationLevel = 1
        menuItem.isEnabled = false
        return menuItem
    }

    private func makeMenuItem(
        _ command: DockItemContextMenuCommand,
        item: DockItem
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(
            title: command.title,
            action: #selector(performContextMenuAction),
            keyEquivalent: ""
        )
        menuItem.target = self
        menuItem.isEnabled = command.isEnabled
        menuItem.representedObject = DockItemContextMenuInvocation(
            item: item,
            action: command.action
        )
        return menuItem
    }

    @objc private func performContextMenuAction(_ sender: NSMenuItem) {
        guard let invocation = sender.representedObject as? DockItemContextMenuInvocation else {
            return
        }
        let handler = onContextAction
        DispatchQueue.main.async {
            handler?(invocation.item, invocation.action)
        }
    }

    private func setContextMenuPresented(_ presented: Bool) {
        guard isContextMenuPresented != presented else { return }
        isContextMenuPresented = presented
        onContextMenuPresentationChange?(self, presented)
    }

    private func trackPrimaryMouseDown(_ sourceEvent: NSEvent) {
        guard sourceEvent.type == .leftMouseDown,
              let window,
              window.isVisible,
              isEnabled,
              let pressedItem = item else { return }

        let pressedIdentity = pressedItem.identity
        let supportsFileDrag = pressedItem.kind.shortcutID != nil
        let startScreenPoint = window.convertPoint(
            toScreen: sourceEvent.locationInWindow
        )
        let startTime = ProcessInfo.processInfo.systemUptime
        let longPressDeadline = Date(
            timeIntervalSinceNow: DockPrimaryPressPolicy.minimumPressDuration
        )
        var movementToleranceExceeded = false
        var isLongPressEligible = true

        isTrackingPrimaryPress = true
        defer { isTrackingPrimaryPress = false }

        while window.isVisible,
              isEnabled,
              item?.identity == pressedIdentity {
            let waitUntil = isLongPressEligible ? longPressDeadline : .distantFuture
            guard let nextEvent = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp, .mouseMoved],
                until: waitUntil,
                inMode: .eventTracking,
                dequeue: true
            ) else {
                guard isLongPressEligible else { continue }

                let currentScreenPoint = NSEvent.mouseLocation
                movementToleranceExceeded = movementToleranceExceeded
                    || DockPrimaryPressPolicy.exceededMovementTolerance(
                        from: startScreenPoint,
                        to: currentScreenPoint
                    )
                guard NSEvent.pressedMouseButtons
                        & DockPrimaryPressPolicy.primaryMouseButtonMask != 0 else {
                    return
                }

                let isPointerInside = containsScreenPoint(
                    currentScreenPoint,
                    in: window
                )
                let action = DockPrimaryPressPolicy.action(
                    eventType: nil,
                    elapsed: max(
                        DockPrimaryPressPolicy.minimumPressDuration,
                        ProcessInfo.processInfo.systemUptime - startTime
                    ),
                    movementToleranceExceeded: movementToleranceExceeded,
                    isPointerInside: isPointerInside,
                    supportsFileDrag: supportsFileDrag
                )
                if action == .presentContextMenu,
                   isEnabled,
                   item?.identity == pressedIdentity {
                    presentContextMenu(for: sourceEvent)
                    return
                }

                // Missing the deadline while outside or after moving cancels
                // only the long press. A later mouseUp still completes or
                // cancels the ordinary click normally.
                isLongPressEligible = false
                continue
            }

            let screenPoint = window.convertPoint(
                toScreen: nextEvent.locationInWindow
            )
            movementToleranceExceeded = movementToleranceExceeded
                || DockPrimaryPressPolicy.exceededMovementTolerance(
                    from: startScreenPoint,
                    to: screenPoint
                )
            if movementToleranceExceeded {
                isLongPressEligible = false
            }

            let action = DockPrimaryPressPolicy.action(
                eventType: nextEvent.type,
                elapsed: ProcessInfo.processInfo.systemUptime - startTime,
                movementToleranceExceeded: movementToleranceExceeded,
                isPointerInside: containsWindowPoint(nextEvent.locationInWindow),
                supportsFileDrag: supportsFileDrag
            )
            switch action {
            case .continueTracking:
                continue
            case .activate:
                guard let currentItem = item,
                      currentItem.identity == pressedIdentity else { return }
                onPress?(currentItem)
                return
            case .beginFileDrag:
                beginFileDrag(with: normalizedFileDragEvent(nextEvent))
                return
            case .presentContextMenu:
                presentContextMenu(for: sourceEvent)
                return
            case .cancel:
                return
            }
        }
    }

    private func containsWindowPoint(_ point: NSPoint) -> Bool {
        containsInteractionPoint(convert(point, from: nil))
    }

    private func containsScreenPoint(_ point: NSPoint, in window: NSWindow) -> Bool {
        containsWindowPoint(window.convertPoint(fromScreen: point))
    }

    private func normalizedFileDragEvent(_ sourceEvent: NSEvent) -> NSEvent {
        let eventType = DockPrimaryPressPolicy.fileDragEventType(
            for: sourceEvent.type
        )
        guard eventType != sourceEvent.type, let window else { return sourceEvent }
        return NSEvent.mouseEvent(
            with: eventType,
            location: sourceEvent.locationInWindow,
            modifierFlags: sourceEvent.modifierFlags,
            timestamp: sourceEvent.timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: sourceEvent.eventNumber,
            clickCount: sourceEvent.clickCount,
            pressure: sourceEvent.pressure
        ) ?? sourceEvent
    }

    private func beginFileDrag(with event: NSEvent) {
        guard let item,
              let shortcutID = item.kind.shortcutID,
              case let .fileShortcut(_, _, isAvailable) = item.kind,
              isAvailable,
              let icon = iconImage else { return }
        let pasteboardItem = NSPasteboardItem()
        let payload = DockInternalShortcutDrag(
            shortcutID: shortcutID,
            fileURL: item.applicationURL
        )
        if let data = try? JSONEncoder().encode(payload) {
            pasteboardItem.setData(data, forType: .echoDockInternalShortcut)
        }
        pasteboardItem.setString(
            item.applicationURL.absoluteString,
            forType: .fileURL
        )
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(
            magnifiedIconFrame,
            contents: icon
        )
        isFileDragSessionActive = true
        _ = beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor draggingContext: NSDraggingContext
    ) -> NSDragOperation {
        [.copy, .move, .delete]
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isTrackingPrimaryPress = false
        isFileDragSessionActive = false
    }

}

extension NSPasteboard.PasteboardType {
    static let echoDockInternalShortcut = NSPasteboard.PasteboardType(
        "com.baikaihao.EchoDock.internal-file-shortcut"
    )
}

private final class DockItemContextMenuInvocation: NSObject {
    let item: DockItem
    let action: DockItemContextAction

    init(item: DockItem, action: DockItemContextAction) {
        self.item = item
        self.action = action
    }
}
