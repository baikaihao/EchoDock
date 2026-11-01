import AppKit

/// Both windows belong to one drag destination, including the gap below the Dock.
struct DockFileDragRegion {
    let panelFrame: NSRect
    let receiverFrame: NSRect?
    var position: DockPosition = .bottom

    func contains(_ screenLocation: NSPoint) -> Bool {
        func includes(_ frame: NSRect) -> Bool {
            frame.width > 0 && frame.height > 0
                && screenLocation.x >= frame.minX && screenLocation.x <= frame.maxX
                && screenLocation.y >= frame.minY && screenLocation.y <= frame.maxY
        }
        return includes(panelFrame) || receiverFrame.map(includes) == true
    }

    func interactionLocation(for screenLocation: NSPoint) -> NSPoint {
        guard contains(screenLocation) else {
            return screenLocation
        }
        // Project only the Dock's internal hover/drop coordinates. The system
        // pointer and file drag image retain their original screen position.
        return position.projectedLocation(screenLocation, panel: panelFrame)
    }
}
