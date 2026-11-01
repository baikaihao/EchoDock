import AppKit

@MainActor
struct FileUndoMenuAction {
    let isAvailable: () -> Bool
    let perform: () -> Void

    static let unavailable = FileUndoMenuAction(isAvailable: { false }, perform: {})

    func makeMenuItem(target: AnyObject, action: Selector) -> NSMenuItem {
        let title = L10n.text("fileUndo.action")
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.isEnabled = isAvailable()
        item.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: title)
        return item
    }
}
