import AppKit

enum DockPosition: String, Codable, CaseIterable, Sendable {
    case top, bottom, left, right

    var isVertical: Bool { self == .left || self == .right }
    var localizationKey: String { "settings.appearance.position.\(rawValue)" }

    /// Existing layout algorithms use x along the strip and y toward the desktop.
    func layoutSize(for size: NSSize) -> NSSize {
        isVertical ? NSSize(width: size.height, height: size.width) : size
    }

    func viewRect(_ rect: NSRect, in size: NSSize, flippedVertical: Bool = false) -> NSRect {
        switch self {
        case .bottom: return rect
        case .top:
            return NSRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
        case .left, .right:
            return NSRect(
                x: self == .left ? rect.minY : size.height - rect.maxY,
                y: flippedVertical ? rect.minX : size.width - rect.maxX,
                width: rect.height, height: rect.width
            )
        }
    }

    func layoutRect(_ rect: NSRect, in size: NSSize, flippedVertical: Bool = false) -> NSRect {
        switch self {
        case .bottom: return rect
        case .top: return viewRect(rect, in: size)
        case .left, .right:
            return NSRect(
                x: flippedVertical ? rect.minY : size.width - rect.maxY,
                y: self == .left ? rect.minX : size.height - rect.maxX,
                width: rect.height, height: rect.width
            )
        }
    }

    func layoutPoint(_ point: NSPoint, in size: NSSize, flippedVertical: Bool = false) -> NSPoint {
        layoutRect(NSRect(origin: point, size: .zero), in: size, flippedVertical: flippedVertical).origin
    }

    func viewTransform(in size: NSSize) -> CGAffineTransform {
        switch self {
        case .bottom: return .identity
        case .top: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        case .left: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
        case .right: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: size.height, ty: size.width)
        }
    }

    func hiddenOffset(for size: NSSize) -> NSPoint {
        switch self {
        case .bottom: return NSPoint(x: 0, y: -size.height)
        case .top: return NSPoint(x: 0, y: size.height)
        case .left: return NSPoint(x: -size.width, y: 0)
        case .right: return NSPoint(x: size.width, y: 0)
        }
    }

    func panelFrame(size: NSSize, display: NSRect, topInset: CGFloat = 0) -> NSRect {
        let centerX = display.midX - size.width / 2
        let centerY = (display.minY + display.maxY - topInset) / 2 - size.height / 2
        switch self {
        case .bottom: return NSRect(x: centerX, y: display.minY + 6, width: size.width, height: size.height)
        case .top: return NSRect(x: centerX, y: display.maxY - topInset - 6 - size.height, width: size.width, height: size.height)
        case .left: return NSRect(x: display.minX + 6, y: centerY, width: size.width, height: size.height)
        case .right: return NSRect(x: display.maxX - 6 - size.width, y: centerY, width: size.width, height: size.height)
        }
    }

    func hotZone(in display: NSRect, depth: CGFloat = 3) -> NSRect {
        let depth = max(0, min(depth, isVertical ? display.width : display.height))
        switch self {
        case .bottom: return NSRect(x: display.minX, y: display.minY, width: display.width, height: depth)
        case .top: return NSRect(x: display.minX, y: display.maxY - depth, width: display.width, height: depth)
        case .left: return NSRect(x: display.minX, y: display.minY, width: depth, height: display.height)
        case .right: return NSRect(x: display.maxX - depth, y: display.minY, width: depth, height: display.height)
        }
    }

    func normalizedLocation(_ point: NSPoint, display: NSRect, panel: NSRect) -> NSPoint {
        guard point.x >= display.minX, point.x <= display.maxX,
              point.y >= display.minY, point.y <= display.maxY else { return point }
        return projectedLocation(point, panel: panel)
    }

    func projectedLocation(_ point: NSPoint, panel: NSRect) -> NSPoint {
        switch self {
        case .bottom: return NSPoint(x: point.x, y: max(point.y, panel.minY))
        case .top: return NSPoint(x: point.x, y: min(point.y, panel.maxY - 0.001))
        case .left: return NSPoint(x: max(point.x, panel.minX), y: point.y)
        case .right: return NSPoint(x: min(point.x, panel.maxX - 0.001), y: point.y)
        }
    }

    func holdRegion(panel: NSRect, display: NSRect, margin: CGFloat = 8) -> NSRect {
        switch self {
        case .bottom:
            return NSRect(x: display.minX, y: display.minY, width: display.width,
                          height: max(0, min(display.maxY, panel.maxY + margin) - display.minY))
        case .top:
            let y = max(display.minY, panel.minY - margin)
            return NSRect(x: display.minX, y: y, width: display.width, height: display.maxY - y)
        case .left:
            return NSRect(x: display.minX, y: display.minY,
                          width: max(0, min(display.maxX, panel.maxX + margin) - display.minX), height: display.height)
        case .right:
            let x = max(display.minX, panel.minX - margin)
            return NSRect(x: x, y: display.minY, width: display.maxX - x, height: display.height)
        }
    }

    func sharesEdge(at point: NSPoint, display: NSRect, other: NSRect) -> Bool {
        switch self {
        case .bottom: return abs(other.maxY - display.minY) <= 1 && point.x >= other.minX && point.x <= other.maxX
        case .top: return abs(other.minY - display.maxY) <= 1 && point.x >= other.minX && point.x <= other.maxX
        case .left: return abs(other.maxX - display.minX) <= 1 && point.y >= other.minY && point.y <= other.maxY
        case .right: return abs(other.minX - display.maxX) <= 1 && point.y >= other.minY && point.y <= other.maxY
        }
    }

    /// Normalize Accessibility's downward-y coordinates to a bottom-edge Dock.
    func canonicalAccessibilityFrame(_ rect: CGRect) -> CGRect {
        switch self {
        case .bottom: return rect
        case .top: return CGRect(x: rect.minX, y: -rect.maxY, width: rect.width, height: rect.height)
        case .left: return CGRect(x: rect.minY, y: -rect.maxX, width: rect.height, height: rect.width)
        case .right: return CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width)
        }
    }

    func physicalAccessibilityFrame(_ rect: CGRect) -> CGRect {
        switch self {
        case .bottom: return rect
        case .top: return canonicalAccessibilityFrame(rect)
        case .left: return CGRect(x: -rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        case .right: return CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width)
        }
    }
}
