import AppKit
import Testing
@testable import EchoDock

struct DockPositionGeometryTests {
    @Test(arguments: DockPosition.allCases, [false, true])
    func layoutCoordinatesRoundTrip(position: DockPosition, flipped: Bool) {
        let size = NSSize(width: 480, height: 100)
        let rect = NSRect(x: 70, y: 8, width: 53, height: 72)
        let physical = position.viewRect(rect, in: size, flippedVertical: flipped)
        #expect(position.layoutRect(physical, in: size, flippedVertical: flipped) == rect)
        #expect(physical.size == position.layoutSize(for: rect.size))
    }

    @Test(arguments: DockPosition.allCases)
    func accessibilityCoordinatesRoundTrip(position: DockPosition) {
        let rect = CGRect(x: -1_600, y: -200, width: 1_100, height: 700)
        #expect(position.physicalAccessibilityFrame(position.canonicalAccessibilityFrame(rect)) == rect)
    }

    @Test(arguments: DockPosition.allCases)
    func panelAndTriggerFollowTheSelectedDisplayEdge(position: DockPosition) {
        let display = NSRect(x: -1_440, y: -200, width: 1_440, height: 900)
        let size = position.layoutSize(for: NSSize(width: 400, height: 72))
        let frame = position.panelFrame(size: size, display: display, topInset: 38)
        let zone = position.hotZone(in: display)
        let pointer = NSPoint(x: zone.midX, y: zone.midY)
        let projected = position.normalizedLocation(pointer, display: display, panel: frame)
        #expect(position.holdRegion(panel: frame, display: display).contains(pointer))
        switch position {
        case .bottom: #expect(frame.minY == display.minY + 6); #expect(projected.y == frame.minY)
        case .top: #expect(frame.maxY == display.maxY - 44); #expect(abs(projected.y - frame.maxY) < 0.01)
        case .left: #expect(frame.minX == display.minX + 6); #expect(projected.x == frame.minX)
        case .right: #expect(frame.maxX == display.maxX - 6); #expect(abs(projected.x - frame.maxX) < 0.01)
        }
        #expect(display.contains(frame))
    }

    @Test(arguments: DockPosition.allCases)
    func windowReservationLeavesSpaceOnTheSelectedSide(position: DockPosition) throws {
        let physical = CGRect(x: -1_440, y: -100, width: 1_440, height: 900)
        let visible = CGRect(x: -1_440, y: -76, width: 1_440, height: 876)
        let display = WindowReservationDisplayGeometry(
            identity: DisplayIdentity(rawValue: "test"), frame: physical,
            visibleFrame: visible, reservedHeight: 80, position: position
        )
        let adjustment = try #require(WindowReservationGeometryPolicy.adjustment(for: visible, displays: [display]))
        #expect(adjustment.targetFrame == display.availableFrame)
        switch position {
        case .bottom: #expect(adjustment.targetFrame.maxY == physical.maxY - 80)
        case .top: #expect(adjustment.targetFrame.minY == physical.minY + 80)
        case .left: #expect(adjustment.targetFrame.minX == physical.minX + 80)
        case .right: #expect(adjustment.targetFrame.maxX == physical.maxX - 80)
        }
        #expect(WindowReservationGeometryPolicy.adjustment(for: physical, displays: [display]) == nil)
    }

    @Test(arguments: DockPosition.allCases)
    func tooltipSitsTowardTheDesktop(position: DockPosition) {
        let anchor = CGRect(x: 500, y: 400, width: 48, height: 48)
        let size = NSSize(width: 150, height: 63)
        let origin = DockTooltipStyle.panelOrigin(
            anchorScreenRect: anchor, gap: 4, screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            panelSize: size, backingScaleFactor: 2, position: position
        )
        let visible = DockTooltipStyle.visualContentRect(in: CGRect(origin: origin, size: size))
        switch position {
        case .bottom: #expect(visible.minY >= anchor.maxY + 4)
        case .top: #expect(visible.maxY <= anchor.minY - 4)
        case .left: #expect(visible.minX >= anchor.maxX + 4)
        case .right: #expect(visible.maxX <= anchor.minX - 4)
        }
    }
}

@MainActor
struct DockPositionViewTests {
    @Test
    func preferenceDefaultsToBottomPersistsAndResets() throws {
        let suite = "DockPositionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        #expect(preferences.dockPosition == .bottom)
        preferences.dockPosition = .right
        #expect(PreferencesStore(defaults: defaults).dockPosition == .right)
        preferences.restoreAppearanceDefaults()
        #expect(preferences.dockPosition == .bottom)
        defaults.set("invalid", forKey: "dockPosition")
        #expect(preferences.dockPosition == .bottom)
    }

    @Test(arguments: DockPosition.allCases)
    func iconsRemainUprightAndFollowReadingOrder(position: DockPosition) throws {
        let content = DockContentView()
        let panel = DockPanel()
        panel.contentView = content
        defer { panel.orderOut(nil) }
        let items = (0..<4).map { index in
            DockItem(identity: ApplicationIdentity(rawValue: "position:\(index)"),
                     bundleIdentifier: nil, applicationURL: Bundle.main.bundleURL,
                     displayName: "Application \(index)", section: .pinned, kind: .application,
                     isRunning: true, isActive: false, isHidden: false, transientState: .normal)
        }
        content.apply(
            snapshot: DockSnapshot(revision: 1, items: items, pinnedItemCount: items.count,
                                   syncStatus: DockSnapshot.empty.syncStatus),
            iconSize: 48, maxWidth: 800, backgroundTransparency: 0.17,
            backgroundStyle: .classic, magnificationEnabled: false, position: position
        )
        panel.setFrame(CGRect(origin: .zero, size: content.frame.size), display: false)
        content.layoutSubtreeIfNeeded()
        let buttons = descendants(DockItemButton.self, in: content).sorted {
            ($0.item?.identity.rawValue ?? "") < ($1.item?.identity.rawValue ?? "")
        }
        #expect(buttons.count == items.count)
        let frames = buttons.map { $0.iconFrame(in: content) }
        for (button, frame) in zip(buttons, frames) {
            #expect(button.frameRotation == 0)
            #expect(button.boundsRotation == 0)
            #expect(abs(frame.width - 48) < 0.01)
            #expect(abs(frame.height - 48) < 0.01)
            #expect(content.bounds.contains(frame))
        }
        for pair in zip(frames, frames.dropFirst()) {
            if position.isVertical { #expect(pair.0.midY > pair.1.midY) }
            else { #expect(pair.0.midX < pair.1.midX) }
        }
        if position.isVertical { #expect(content.frame.height > content.frame.width) }
        else { #expect(content.frame.width > content.frame.height) }
    }

    @Test
    func appearanceControlReadsAndWritesThePosition() throws {
        let suite = "DockPositionSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.dockPosition = .right
        let controller = AppearanceSettingsViewController(preferences: preferences)
        _ = controller.view
        controller.refresh()
        let control = try #require(descendants(NSSegmentedControl.self, in: controller.view).first {
            $0.segmentCount == 4
        })
        #expect(control.selectedSegment == DockPosition.allCases.firstIndex(of: .right))
        control.selectedSegment = try #require(DockPosition.allCases.firstIndex(of: .left))
        if let action = control.action { NSApp.sendAction(action, to: control.target, from: control) }
        #expect(preferences.dockPosition == .left)
    }

    @Test(arguments: DockPosition.allCases)
    func overflowStartsAtTheFirstItemAndScrollsToTheLast(position: DockPosition) throws {
        let (panel, content, buttons) = makeContent(position: position, count: 30, magnification: false, maximumLength: 240)
        defer { panel.orderOut(nil) }
        let first = try #require(buttons.first)
        let last = try #require(buttons.last)
        #expect(content.bounds.intersects(first.iconFrame(in: content)))
        #expect(!content.bounds.intersects(last.iconFrame(in: content)))
        let scroll = try #require(descendants(NSScrollView.self, in: content).first)
        let document = try #require(scroll.documentView)
        let origin = position.isVertical
            ? NSPoint(x: 0, y: document.frame.height - scroll.contentView.bounds.height)
            : NSPoint(x: document.frame.width - scroll.contentView.bounds.width, y: 0)
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(content.bounds.intersects(last.iconFrame(in: content)))
    }

    @Test(arguments: DockPosition.allCases)
    func pointerMagnifiesTheCorrectUprightIconAndKeepsTooltipDirection(position: DockPosition) async throws {
        let (panel, content, buttons) = makeContent(position: position, count: 4, magnification: true, maximumLength: 800)
        defer { content.resetInteraction(); panel.orderOut(nil) }
        let first = try #require(buttons.first)
        var tooltip: DockTooltipPresentation?
        content.onTooltipPresentation = { tooltip = $0 }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        panel.setFrame(position.panelFrame(size: content.frame.size, display: screen.insetBy(dx: 120, dy: 120)), display: false)
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        let frame = first.iconFrame(in: content)
        let local = NSPoint(x: frame.midX, y: frame.midY)
        let location = panel.convertPoint(toScreen: content.convert(local, to: nil))
        #expect(content.shouldReceiveMouse(at: location))
        content.reconcilePointer(screenLocation: location, allowsSyntheticEntry: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while first.iconFrame(in: content).width <= 48, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let strip = descendants(NSScrollView.self, in: content).first?.documentView
        let states = strip.map { view in Mirror(reflecting: view).children.filter {
            ["isPointerInside", "pointerX", "magnificationTransition", "isFrameClockRunning"].contains($0.label ?? "")
        }.map { "\($0.label ?? ""): \($0.value)" }.joined(separator: ", ") } ?? "missing strip"
        #expect(first.iconFrame(in: content).width > 48, "\(position): \(states)")
        #expect(tooltip?.position == position)
        #expect(tooltip?.text == first.item?.displayName)
    }

    @Test(arguments: DockPosition.allCases)
    func realPanelMagnificationDoesNotRecursivelyResizeOrOscillate(position: DockPosition) async throws {
        let suite = "DockPositionStressTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.dockPosition = position
        preferences.dockBackgroundStyle = .ice
        preferences.magnificationEnabled = true
        preferences.autoHide = false
        let display = CGRect(x: 10_000, y: -900, width: 1_440, height: 900)
        let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = DockPanelController(
            descriptor: DisplayDescriptor(identity: DisplayIdentity(rawValue: suite), displayID: 0,
                localizedName: "Stress display", frame: display, isMain: false, isBuiltIn: false, mirroredDisplayID: nil),
            preferences: preferences, onItemAction: { _ in }, onItemContextAction: { _, _ in },
            contextMenuStateProvider: { _ in .unavailable }, onDropRequest: { _ in false }
        )
        defer { controller.destroy() }
        let items = (0..<30).map { index in
            DockItem(identity: ApplicationIdentity(rawValue: "stress:\(index)"), bundleIdentifier: nil,
                     applicationURL: Bundle.main.bundleURL, displayName: "Application \(index)",
                     section: .pinned, kind: .application, isRunning: true, isActive: false, isHidden: false, transientState: .normal)
        }
        controller.apply(snapshot: DockSnapshot(revision: 1, items: items, pinnedItemCount: items.count,
            syncStatus: DockSnapshot.empty.syncStatus), itemAnimationsEnabled: false)
        controller.applyPreferences()
        let panel = try #require(NSApp.windows.first {
            !previousWindows.contains(ObjectIdentifier($0)) && $0.contentView is DockPanelPresentationView
        })
        var resizeCount = 0
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { resizeCount += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let zone = position.hotZone(in: display)
        let pointer = NSPoint(x: zone.midX, y: zone.midY)
        for _ in 0..<12 {
            controller.processMouse(location: pointer, pressedButtons: 0, now: Date())
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(180))
        #expect(panel.isVisible)
        #expect(panel.frame.width.isFinite && panel.frame.height.isFinite)
        #expect(resizeCount < 20, "\(position): resize loop (\(resizeCount))")
    }

    @Test
    func tallGlassUsesItsThicknessAndReusesAVerticalStretchMap() throws {
        let surface = DockLiquidGlassSurfaceView(frame: NSRect(x: 0, y: 0, width: 72, height: 1_200))
        surface.updateGeometry(bodyRect: surface.bounds, cornerRadius: 20, backingScale: 2)
        guard surface.isUsingCustomRenderer else { return }
        #expect(surface.optics == DockLiquidGlassOptics.dock(bodyHeight: 72))
        let map = try #require(surface.displacementMap)
        #expect(map.descriptor.isVertical)
        #expect(map.widthPixels == 144)
        #expect(map.heightPixels < 300)
        #expect(map.contentsCenter.height < 0.1)
        let generation = surface.mapGenerationCount
        surface.frame.size.height = 1_800
        surface.updateGeometry(bodyRect: surface.bounds, cornerRadius: 20, backingScale: 2)
        #expect(surface.mapGenerationCount == generation)
    }

    private func makeContent(position: DockPosition, count: Int, magnification: Bool, maximumLength: CGFloat)
        -> (DockPanel, DockContentView, [DockItemButton]) {
        let content = DockContentView()
        let panel = DockPanel()
        panel.contentView = DockPanelPresentationView(presentedView: content)
        let items = (0..<count).map { index in
            DockItem(identity: ApplicationIdentity(rawValue: String(format: "item:%03d", index)),
                     bundleIdentifier: nil, applicationURL: Bundle.main.bundleURL,
                     displayName: "Application \(index)", section: .pinned, kind: .application,
                     isRunning: true, isActive: false, isHidden: false, transientState: .normal)
        }
        content.apply(snapshot: DockSnapshot(revision: 1, items: items, pinnedItemCount: items.count, syncStatus: DockSnapshot.empty.syncStatus),
                      iconSize: 48, maxWidth: maximumLength, backgroundTransparency: 0.17, backgroundStyle: .classic,
                      magnificationEnabled: magnification, position: position)
        panel.setFrame(NSRect(x: 10_000, y: 0, width: content.frame.width, height: content.frame.height), display: false)
        content.onPreferredSizeChange = { [weak panel, weak content] size in
            guard let panel, let content else { return }
            panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: false)
            content.layoutSubtreeIfNeeded()
        }
        content.layoutSubtreeIfNeeded()
        let buttons = descendants(DockItemButton.self, in: content).sorted {
            ($0.item?.identity.rawValue ?? "") < ($1.item?.identity.rawValue ?? "")
        }
        return (panel, content, buttons)
    }

    private func descendants<View: NSView>(_ type: View.Type, in root: NSView) -> [View] {
        root.subviews.flatMap { child -> [View] in
            ((child as? View).map { [$0] } ?? []) + descendants(type, in: child)
        }
    }
}
