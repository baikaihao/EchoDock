import AppKit
import Testing
@testable import EchoDock

struct DockFileDragRegionTests {
    @Test(arguments: [CGFloat(0), -900])
    func bottomGapContinuesTheSameDrag(displayBottom: CGFloat) {
        let region = DockFileDragRegion(
            panelFrame: NSRect(x: 500, y: displayBottom + 6, width: 440, height: 80),
            receiverFrame: NSRect(x: 470, y: displayBottom, width: 500, height: 78)
        )
        for offset in [CGFloat(0), 2, 5, 6, 20] {
            let point = NSPoint(x: 720, y: displayBottom + offset)
            #expect(region.contains(point))
            #expect(region.interactionLocation(for: point) == NSPoint(
                x: point.x,
                y: max(point.y, region.panelFrame.minY)
            ))
        }
        for point in [NSPoint(x: 450, y: displayBottom),
                      NSPoint(x: 720, y: displayBottom - 1),
                      NSPoint(x: 720, y: displayBottom + 100),
                      NSPoint(x: 480, y: displayBottom + 80)] {
            #expect(!region.contains(point))
            #expect(region.interactionLocation(for: point) == point)
        }
    }

    @Test
    func inactiveReceiverDoesNotExtendTheDestination() {
        let region = DockFileDragRegion(
            panelFrame: NSRect(x: 500, y: 6, width: 440, height: 80),
            receiverFrame: nil
        )
        let point = NSPoint(x: 720, y: 2)
        #expect(!region.contains(point))
        #expect(region.interactionLocation(for: point) == point)
    }

    @Test @MainActor
    func draggingBelowPanelKeepsItsSizeAndLabelUntilLeavingBothWindows() throws {
        let suite = "DockFileDragRegionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.isEnabled = true
        preferences.autoHide = false
        preferences.magnificationEnabled = false
        let descriptor = DisplayDescriptor(
            identity: DisplayIdentity(rawValue: suite), displayID: 0,
            localizedName: "Test display",
            frame: CGRect(x: 10_000, y: -900, width: 1_440, height: 900),
            isMain: false, isBuiltIn: false, mirroredDisplayID: nil
        )
        let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = DockPanelController(
            descriptor: descriptor, preferences: preferences,
            onItemAction: { _ in }, onItemContextAction: { _, _ in },
            contextMenuStateProvider: { _ in .unavailable }, onDropRequest: { _ in false }
        )
        defer { controller.destroy() }
        let item = DockItem(
            identity: ApplicationIdentity(rawValue: "test:drag-hover"),
            bundleIdentifier: nil, applicationURL: Bundle.main.bundleURL,
            displayName: "Test application", section: .pinned, kind: .application,
            isRunning: true, isActive: false, isHidden: false, transientState: .normal
        )
        controller.apply(snapshot: DockSnapshot(
            revision: 1, items: [item], pinnedItemCount: 1, syncStatus: DockSnapshot.empty.syncStatus
        ), itemAnimationsEnabled: false)
        controller.applyPreferences()
        let panel = try #require(NSApp.windows.first {
            !previousWindows.contains(ObjectIdentifier($0)) && $0.contentView is DockContentView
        })
        let content = try #require(panel.contentView as? DockContentView)
        #expect(panel.isVisible)
        var labels: [String?] = []
        content.onTooltipPresentation = { labels.append($0?.text) }
        let drag = FileDragInfo(window: panel)
        defer { drag.draggingPasteboard.releaseGlobally() }
        drag.draggingLocation = NSPoint(x: panel.frame.width / 2, y: 20)
        _ = content.draggingEntered(drag)
        let lockedSize = content.frame.size
        #expect(labels.last == .some(item.displayName))
        let initialLabelClearCount = labels.filter { $0 == nil }.count
        let region = try #require(content.fileDragRegionProvider?())
        #expect(region.receiverFrame != nil)
        let receiver = try #require(NSApp.windows.first {
            !previousWindows.contains(ObjectIdentifier($0)) && $0.level == EchoDockWindowLevel.dragReceiver
        })
        drag.draggingDestinationWindow = receiver

        for offset in [CGFloat(5), 2, 0, 3, 5, 0] {
            let point = NSPoint(x: panel.frame.midX, y: descriptor.frame.minY + offset)
            let beforeGlobalSample = labels.count
            controller.processMouse(location: point, pressedButtons: 1, now: Date(), isFileDrag: true)
            #expect(content.frame.size == lockedSize)
            #expect(labels.dropFirst(beforeGlobalSample).allSatisfy { $0 != nil }, "Global sample at \(offset): \(labels)")
            drag.draggingLocation = receiver.convertPoint(fromScreen: point)
            let beforeApplicationSample = labels.count
            _ = content.draggingUpdated(drag)
            #expect(content.frame.size == lockedSize)
            #expect(labels.last == .some(item.displayName))
            #expect(labels.dropFirst(beforeApplicationSample).allSatisfy { $0 != nil }, "Application sample at \(offset): \(labels)")
        }
        // Starting the session may clear the old hover during layout. It must
        // not clear again as physical and application drag samples alternate.
        #expect(labels.filter { $0 == nil }.count == initialLabelClearCount)

        controller.processMouse(
            location: NSPoint(x: panel.frame.midX, y: panel.frame.maxY + 100),
            pressedButtons: 1, now: Date(), isFileDrag: true
        )
        #expect(content.frame.size != lockedSize)
        #expect(labels.last == .some(nil))
    }
}

@MainActor
private final class FileDragInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingLocation: NSPoint = .zero
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(window: NSWindow) {
        draggingDestinationWindow = window
        super.init()
        draggingPasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/EchoDock-test-drag.txt")])
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
