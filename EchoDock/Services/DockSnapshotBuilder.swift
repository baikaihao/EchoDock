import Foundation

struct DockSnapshotBuildResult: Equatable {
    let items: [DockItem]
    let pinnedItemCount: Int
}

enum DockSnapshotBuilder {
    static func build(
        finder: PinnedApplication?,
        pinnedApplications: [PinnedApplication],
        runningApplications: [RunningApplicationRecord],
        showRunningApplications: Bool,
        transientStates: [ApplicationIdentity: DockItemTransientState],
        fileShortcuts: [ResolvedDockFileShortcut] = []
    ) -> DockSnapshotBuildResult {
        var runningByIdentity: [ApplicationIdentity: RunningApplicationRecord] = [:]
        for running in runningApplications.sorted(by: { $0.stableOrder < $1.stableOrder }) {
            if runningByIdentity[running.identity] == nil {
                runningByIdentity[running.identity] = running
            }
        }

        var pinnedIdentities = Set<ApplicationIdentity>()
        var items: [DockItem] = []

        if let finder, pinnedIdentities.insert(finder.identity).inserted {
            items.append(makePinnedItem(
                finder,
                running: runningByIdentity[finder.identity],
                transientState: transientStates[finder.identity] ?? .normal
            ))
        }

        for pinned in pinnedApplications.sorted(by: { $0.sourceOrder < $1.sourceOrder })
        where pinnedIdentities.insert(pinned.identity).inserted {
            items.append(makePinnedItem(
                pinned,
                running: runningByIdentity[pinned.identity],
                transientState: transientStates[pinned.identity] ?? .normal
            ))
        }

        let pinnedItemCount = items.count
        if showRunningApplications {
            for running in runningApplications.sorted(by: { $0.stableOrder < $1.stableOrder })
            where !pinnedIdentities.contains(running.identity) {
                guard pinnedIdentities.insert(running.identity).inserted else { continue }
                items.append(DockItem(
                    identity: running.identity,
                    bundleIdentifier: running.bundleIdentifier,
                    applicationURL: running.applicationURL,
                    displayName: running.displayName,
                    section: .running,
                    kind: .application,
                    isRunning: true,
                    isActive: running.isActive,
                    isHidden: running.isHidden,
                    transientState: transientStates[running.identity] ?? .normal
                ))
            }
        }

        for shortcut in fileShortcuts {
            items.append(DockItem(
                identity: ApplicationIdentity(rawValue: "file:\(shortcut.id.uuidString)"),
                bundleIdentifier: nil,
                applicationURL: shortcut.url,
                displayName: shortcut.displayName,
                section: .files,
                kind: .fileShortcut(
                    id: shortcut.id,
                    isDirectory: shortcut.isDirectory,
                    isAvailable: shortcut.isAvailable
                ),
                isRunning: false,
                isActive: false,
                isHidden: false,
                transientState: .normal
            ))
        }

        let trashIdentity = ApplicationIdentity(rawValue: "system:trash")
        items.append(DockItem(
            identity: trashIdentity,
            bundleIdentifier: nil,
            applicationURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".Trash", isDirectory: true),
            displayName: L10n.text("dock.trash"),
            section: .files,
            kind: .trash,
            isRunning: false,
            isActive: false,
            isHidden: false,
            transientState: transientStates[trashIdentity] ?? .normal
        ))

        return DockSnapshotBuildResult(
            items: items,
            pinnedItemCount: pinnedItemCount
        )
    }

    private static func makePinnedItem(
        _ pinned: PinnedApplication,
        running: RunningApplicationRecord?,
        transientState: DockItemTransientState
    ) -> DockItem {
        DockItem(
            identity: pinned.identity,
            bundleIdentifier: pinned.bundleIdentifier,
            applicationURL: pinned.applicationURL,
            displayName: pinned.displayName,
            section: .pinned,
            kind: .application,
            isRunning: running != nil,
            isActive: running?.isActive ?? false,
            isHidden: running?.isHidden ?? false,
            transientState: transientState
        )
    }
}
