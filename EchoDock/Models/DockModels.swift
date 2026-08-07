import Foundation

enum DockBackgroundTransparency {
    static let allowedRange: ClosedRange<CGFloat> = 0...1

    static func clamped(_ value: CGFloat) -> CGFloat {
        min(allowedRange.upperBound, max(allowedRange.lowerBound, value))
    }

    static func materialOpacity(for transparency: CGFloat) -> CGFloat {
        1 - clamped(transparency)
    }
}

enum DockBackgroundBlur {
    static let allowedRange: ClosedRange<CGFloat> = 0...1
    static let defaultValue: CGFloat = 0.5

    static func clamped(_ value: CGFloat) -> CGFloat {
        min(allowedRange.upperBound, max(allowedRange.lowerBound, value))
    }
}

enum DockBackgroundStyle: String, CaseIterable, Sendable {
    case classic
    case liquidGlass
    case ice
}

enum DockBackgroundStyleAvailability {
    static var isSupported: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }
}

enum DockBackgroundTuningPolicy {
    static func allowsTransparencyTuning(
        supportsLiquidGlass: Bool,
        selectedStyle: DockBackgroundStyle,
        reduceTransparency: Bool = false
    ) -> Bool {
        guard !reduceTransparency else { return false }

        switch selectedStyle {
        case .classic, .ice:
            return true
        case .liquidGlass:
            return !supportsLiquidGlass
        }
    }

    static func allowsBackgroundBlurTuning(
        supportsLiquidGlass: Bool,
        selectedStyle: DockBackgroundStyle,
        reduceTransparency: Bool = false
    ) -> Bool {
        !reduceTransparency
            && supportsLiquidGlass
            && selectedStyle == .classic
    }
}

struct ApplicationIdentity: Hashable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(bundleIdentifier: String?, applicationURL: URL?) {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            rawValue = "bundle:\(bundleIdentifier.lowercased())"
        } else if let applicationURL {
            rawValue = "url:\(applicationURL.standardizedFileURL.resolvingSymlinksInPath().path)"
        } else {
            rawValue = "unknown"
        }
    }
}

struct PinnedApplication: Codable, Equatable, Sendable {
    let identity: ApplicationIdentity
    let bundleIdentifier: String?
    let applicationURL: URL
    let displayName: String
    let sourceOrder: Int
}

struct RunningApplicationRecord: Equatable {
    let identity: ApplicationIdentity
    let bundleIdentifier: String?
    let applicationURL: URL
    let displayName: String
    let isActive: Bool
    let isHidden: Bool
    let stableOrder: Int
}

enum DockItemSection: String, Codable, Sendable {
    case pinned
    case running
    case files
}

enum DockItemKind: Equatable, Sendable {
    case application
    case fileShortcut(id: UUID, isDirectory: Bool, isAvailable: Bool)
    case trash
    case dropPlaceholder

    var isApplication: Bool {
        if case .application = self { return true }
        return false
    }

    var shortcutID: UUID? {
        guard case let .fileShortcut(id, _, _) = self else { return nil }
        return id
    }
}

enum DockItemTransientState: Equatable {
    case normal
    case launching
    case failed(String)
}

struct DockItem: Equatable, Identifiable {
    var id: ApplicationIdentity { identity }

    let identity: ApplicationIdentity
    let bundleIdentifier: String?
    let applicationURL: URL
    let displayName: String
    let section: DockItemSection
    let kind: DockItemKind
    let isRunning: Bool
    let isActive: Bool
    let isHidden: Bool
    let transientState: DockItemTransientState

    init(
        identity: ApplicationIdentity,
        bundleIdentifier: String?,
        applicationURL: URL,
        displayName: String,
        section: DockItemSection,
        kind: DockItemKind = .application,
        isRunning: Bool,
        isActive: Bool,
        isHidden: Bool,
        transientState: DockItemTransientState
    ) {
        self.identity = identity
        self.bundleIdentifier = bundleIdentifier
        self.applicationURL = applicationURL
        self.displayName = displayName
        self.section = section
        self.kind = kind
        self.isRunning = isRunning
        self.isActive = isActive
        self.isHidden = isHidden
        self.transientState = transientState
    }
}

enum DockItemContextAction: Int, Equatable, Sendable {
    case revealInFinder
    case open
    case showAllWindows
    case closeWindow
    case show
    case hide
    case quit
    case removeShortcut
}

struct DockItemContextMenuState: Equatable {
    let canCloseWindow: Bool
    let requiresAccessibilityPermission: Bool

    init(
        canCloseWindow: Bool,
        requiresAccessibilityPermission: Bool = false
    ) {
        self.canCloseWindow = canCloseWindow
        self.requiresAccessibilityPermission = requiresAccessibilityPermission
    }

    static let unavailable = DockItemContextMenuState(canCloseWindow: false)
}

struct DockItemContextMenuCommand: Equatable {
    let action: DockItemContextAction
    let title: String
    let isEnabled: Bool
}

struct DockItemContextMenuModel: Equatable {
    let options: [DockItemContextMenuCommand]
    let commands: [DockItemContextMenuCommand]
    let closeWindowNotice: String?

    init(
        options: [DockItemContextMenuCommand],
        commands: [DockItemContextMenuCommand],
        closeWindowNotice: String? = nil
    ) {
        self.options = options
        self.commands = commands
        self.closeWindowNotice = closeWindowNotice
    }
}

enum DockItemContextMenuBuilder {
    static func make(
        for item: DockItem,
        state: DockItemContextMenuState = .unavailable
    ) -> DockItemContextMenuModel {
        switch item.kind {
        case .fileShortcut(_, _, let isAvailable):
            return DockItemContextMenuModel(
                options: [
                    DockItemContextMenuCommand(
                        action: .revealInFinder,
                        title: L10n.text("dock.menu.revealInFinder"),
                        isEnabled: isAvailable
                    )
                ],
                commands: [
                    DockItemContextMenuCommand(
                        action: .open,
                        title: L10n.text("dock.menu.open"),
                        isEnabled: isAvailable
                    ),
                    DockItemContextMenuCommand(
                        action: .removeShortcut,
                        title: L10n.text("dock.menu.removeShortcut"),
                        isEnabled: true
                    )
                ]
            )

        case .trash:
            return DockItemContextMenuModel(
                options: [],
                commands: [
                    DockItemContextMenuCommand(
                        action: .open,
                        title: L10n.text("dock.menu.open"),
                        isEnabled: true
                    )
                ]
            )

        case .dropPlaceholder:
            return DockItemContextMenuModel(options: [], commands: [])

        case .application:
            break
        }

        let reveal = DockItemContextMenuCommand(
            action: .revealInFinder,
            title: L10n.text("dock.menu.revealInFinder"),
            isEnabled: item.applicationURL.isFileURL
        )

        guard item.isRunning else {
            return DockItemContextMenuModel(
                options: [reveal],
                commands: [
                    DockItemContextMenuCommand(
                        action: .open,
                        title: L10n.text("dock.menu.open"),
                        isEnabled: item.transientState != .launching
                    )
                ]
            )
        }

        var commands = [
            DockItemContextMenuCommand(
                action: .showAllWindows,
                title: L10n.text("dock.menu.showAllWindows"),
                isEnabled: true
            ),
            DockItemContextMenuCommand(
                action: .closeWindow,
                title: L10n.text("dock.menu.closeWindow"),
                isEnabled: state.canCloseWindow
            ),
            DockItemContextMenuCommand(
                action: item.isHidden ? .show : .hide,
                title: item.isHidden
                    ? L10n.text("dock.menu.show")
                    : L10n.text("dock.menu.hide"),
                isEnabled: true
            )
        ]
        if !isFinder(item) {
            commands.append(DockItemContextMenuCommand(
                action: .quit,
                title: L10n.text("dock.menu.quit"),
                isEnabled: true
            ))
        }
        return DockItemContextMenuModel(
            options: [reveal],
            commands: commands,
            closeWindowNotice: state.requiresAccessibilityPermission
                ? L10n.text("dock.menu.accessibilityRequired")
                : nil
        )
    }

    static func isFinder(_ item: DockItem) -> Bool {
        item.bundleIdentifier?.caseInsensitiveCompare("com.apple.finder") == .orderedSame
    }
}

enum DockDropDestination: Equatable, Sendable {
    case shortcuts(index: Int)
    case trash
}

struct DockInternalShortcutDrag: Equatable, Codable, Sendable {
    let shortcutID: UUID
    let fileURL: URL
}

struct DockDropRequest: Equatable, Sendable {
    let fileURLs: [URL]
    let sourceShortcutIDs: [UUID]
    let destination: DockDropDestination
}

enum DockSyncStatus: Equatable {
    case normal
    case cached
    case unavailable(String)
}

struct DockSnapshot: Equatable {
    let revision: UInt64
    let items: [DockItem]
    let pinnedItemCount: Int
    let syncStatus: DockSyncStatus

    static let empty = DockSnapshot(
        revision: 0,
        items: [],
        pinnedItemCount: 0,
        syncStatus: .unavailable(L10n.text("dock.sync.notSynced"))
    )
}
