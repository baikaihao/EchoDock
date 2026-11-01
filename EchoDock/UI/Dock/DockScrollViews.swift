import AppKit

final class HorizontalDockScrollView: NSScrollView {
    var position: DockPosition = .bottom {
        didSet {
            guard position.isVertical != oldValue.isVertical, let document = documentView else { return }
            let frame = contentView.frame
            documentView = nil
            let clip = DockAxisClipView(frame: frame)
            clip.vertical = position.isVertical
            clip.drawsBackground = false
            clip.clipsToBounds = false
            contentView = clip
            documentView = document
            contentView.clipsToBounds = false
            contentView.scroll(to: .zero)
        }
    }
    var onScroll: ((NSEvent) -> Void)?
    var onBackgroundContextMenu: ((NSEvent) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onBackgroundContextMenu?(event)
    }

    override func scrollWheel(with event: NSEvent) {
        if position.isVertical {
            super.scrollWheel(with: event)
            onScroll?(event)
            return
        }
        guard let clipView = contentView as NSClipView? else {
            super.scrollWheel(with: event)
            return
        }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        var origin = clipView.bounds.origin
        origin.x += delta
        let maximum = max(0, (documentView?.frame.width ?? 0) - clipView.bounds.width)
        origin.x = min(max(0, origin.x), maximum)
        clipView.scroll(to: origin)
        reflectScrolledClipView(clipView)
        onScroll?(event)
    }
}

private final class DockAxisClipView: NSClipView {
    var vertical = false
    override var isFlipped: Bool { vertical }
}

