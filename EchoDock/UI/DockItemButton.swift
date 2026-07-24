import AppKit
import CoreImage

enum DockRunningIndicatorPresentationPolicy {
    static func isVisible(isRunning: Bool, isEnabled: Bool) -> Bool {
        isEnabled && isRunning
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

    private let iconImageView = NSImageView()
    private let runningIndicator = NSView()
    private let failureImageView = NSImageView()
    private(set) var item: DockItem?
    private var iconSize: CGFloat = 48
    private var magnification: CGFloat = 1
    private var presenceProgress: CGFloat = 1
    private var launchBounceOffset: CGFloat = 0
    private var activeContextMenu: NSMenu?
    private var isContextMenuPresented = false
    private var isTrackingFileDrag = false
    private var isDropTargeted = false

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
        target = self
        action = #selector(didPress)

        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconImageView)

        runningIndicator.wantsLayer = true
        runningIndicator.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
        runningIndicator.layer?.cornerRadius = 2
        addSubview(runningIndicator)

        failureImageView.image = NSImage(
            systemSymbolName: "exclamationmark.circle.fill",
            accessibilityDescription: L10n.text("dock.action.failed")
        )
        failureImageView.contentTintColor = NSColor.systemRed
        failureImageView.imageScaling = .scaleProportionallyUpOrDown
        failureImageView.isHidden = true
        addSubview(failureImageView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        updateIconFrame()
        updateAccessoryFrames()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, super.hitTest(point) != nil else { return nil }
        // Image and status subviews are decorative. Returning the button keeps
        // clicks on the visible icon on the NSButton action path.
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
        } else if item?.kind.shortcutID != nil {
            trackFileMouseDown(event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        guard item?.kind.shortcutID != nil, !isTrackingFileDrag else { return }
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
            && iconImageView.image != nil
        self.item = item
        self.iconSize = iconSize
        switch item.kind {
        case .application, .fileShortcut:
            if !canReuseCurrentImage {
                iconImageView.image = iconProvider.icon(
                    for: item.applicationURL,
                    size: iconSize
                )
            }
        case .trash:
            iconImageView.image = DockTrashIconProvider.image(for: item.applicationURL)
            iconImageView.image?.size = NSSize(width: iconSize, height: iconSize)
        case .dropPlaceholder:
            iconImageView.image = nil
        }
        // Use DockContentView's native-looking capsule instead of AppKit's
        // default tooltip, which can truncate names to "Xco…".
        toolTip = nil
        setAccessibilityLabel(item.displayName)
        runningIndicator.isHidden = !DockRunningIndicatorPresentationPolicy.isVisible(
            isRunning: item.isRunning,
            isEnabled: showsRunningIndicator
        )

        switch item.transientState {
        case .normal:
            failureImageView.isHidden = true
        case .launching:
            failureImageView.isHidden = true
        case .failed:
            failureImageView.isHidden = false
        }
        if case let .fileShortcut(_, _, isAvailable) = item.kind, !isAvailable {
            failureImageView.isHidden = false
        }
        if item.kind == .dropPlaceholder {
            runningIndicator.isHidden = true
            failureImageView.isHidden = true
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
        let iconFrameInWindow = iconImageView.convert(iconImageView.bounds, to: nil)
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
            with: .rightMouseDown,
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
            launchBounceOffset: launchBounceOffset
        )
    }

    func setPresentation(
        magnification value: CGFloat,
        presenceProgress progress: CGFloat,
        launchBounceOffset bounceOffset: CGFloat = 0
    ) {
        let clampedMagnification = min(1.80, max(1, value))
        let clampedProgress = min(1, max(0, progress))
        let clampedBounceOffset = max(0, bounceOffset)
        let magnificationChanged = abs(clampedMagnification - magnification) > 0.0001
        let presenceChanged = abs(clampedProgress - presenceProgress) > 0.0001
        let bounceChanged = abs(clampedBounceOffset - launchBounceOffset) > 0.0001
        if magnificationChanged {
            layer?.zPosition = clampedMagnification
        }
        magnification = clampedMagnification
        presenceProgress = clampedProgress
        launchBounceOffset = clampedBounceOffset
        if abs(alphaValue - clampedProgress) > 0.0001 {
            alphaValue = clampedProgress
        }
        let targetFrame = magnifiedIconFrame
        guard magnificationChanged
                || presenceChanged
                || bounceChanged
                || !NSEqualRects(iconImageView.frame, targetFrame) else { return }
        updateIconFrame()
        updateAccessoryFrames()
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
            x: bounds.midX - side / 2,
            y: originY,
            width: side,
            height: side
        )
    }

    /// Resize the image view itself instead of transforming the whole button.
    /// Presence changes expand or collapse around the icon's visual center;
    /// launch bounce is an independent physical vertical translation.
    private func updateIconFrame() {
        iconImageView.frame = magnifiedIconFrame
    }

    func iconFrame(in view: NSView) -> NSRect {
        iconImageView.convert(iconImageView.bounds, to: view)
    }

    /// Keeps horizontal ownership stable while neighboring icons move, but
    /// excludes the invisible headroom above and below the rendered icon.
    func tooltipHoverFrame(in view: NSView) -> NSRect {
        let controlFrame = convert(bounds, to: view)
        let iconFrame = iconFrame(in: view)
        return NSRect(
            x: controlFrame.minX,
            y: iconFrame.minY,
            width: controlFrame.width,
            height: iconFrame.height
        )
    }

    private func updateAccessoryFrames() {
        let indicatorY = isFlipped ? bounds.maxY - 5 : bounds.minY + 1
        let indicatorFrame = NSRect(
            x: bounds.midX - 2,
            y: indicatorY,
            width: 4,
            height: 4
        )
        if !NSEqualRects(runningIndicator.frame, indicatorFrame) {
            runningIndicator.frame = indicatorFrame
        }
        let iconFrame = magnifiedIconFrame
        let badgeY = isFlipped ? iconFrame.minY + 2 : iconFrame.maxY - 18
        let badgeFrame = NSRect(x: iconFrame.maxX - 18, y: badgeY, width: 16, height: 16)
        if !NSEqualRects(failureImageView.frame, badgeFrame) {
            failureImageView.frame = badgeFrame
        }
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

    private func trackFileMouseDown(_ event: NSEvent) {
        guard let window, let item, item.kind.shortcutID != nil else { return }
        isTrackingFileDrag = true
        defer { isTrackingFileDrag = false }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [
            .leftMouseDragged,
            .leftMouseUp,
            .mouseMoved
        ]) {
            switch next.type {
            case .leftMouseDragged:
                let point = next.locationInWindow
                if hypot(point.x - start.x, point.y - start.y) >= 4 {
                    beginFileDrag(with: next)
                    return
                }
            case .leftMouseUp:
                onPress?(item)
                return
            default:
                continue
            }
        }
    }

    private func beginFileDrag(with event: NSEvent) {
        guard let item,
              let shortcutID = item.kind.shortcutID,
              case let .fileShortcut(_, _, isAvailable) = item.kind,
              isAvailable,
              let icon = iconImageView.image else { return }
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
            iconImageView.convert(iconImageView.bounds, to: self),
            contents: icon
        )
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
        isTrackingFileDrag = false
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
