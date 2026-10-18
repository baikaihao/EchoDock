import AppKit

/// Both windows belong to one drag destination, including the gap below the Dock.
struct DockFileDragRegion {
    let panelFrame: NSRect
    let receiverFrame: NSRect?

    func contains(_ screenLocation: NSPoint) -> Bool {
        panelFrame.contains(screenLocation)
            || receiverFrame?.contains(screenLocation) == true
    }

    func interactionLocation(for screenLocation: NSPoint) -> NSPoint {
        guard contains(screenLocation), screenLocation.y < panelFrame.minY else {
            return screenLocation
        }
        // Project only the Dock's internal hover/drop coordinates. The system
        // pointer and file drag image retain their original screen position.
        return NSPoint(x: screenLocation.x, y: panelFrame.minY)
    }
}
