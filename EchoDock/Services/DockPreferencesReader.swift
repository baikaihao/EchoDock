import AppKit
import CoreFoundation

struct DockPreferenceEntry {
    let bundleIdentifier: String?
    let primaryURL: URL?
    let bookmarkData: Data?
    let fallbackName: String?
    let sourceOrder: Int
}

enum DockPreferencesError: LocalizedError {
    case unavailable
    case invalidRoot

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return L10n.text("dock.error.readPreferences")
        case .invalidRoot:
            return L10n.text("dock.error.invalidPreferences")
        }
    }
}

protocol DockPreferencesReading {
    func readEntries() throws -> [DockPreferenceEntry]
}

final class DockPreferencesReader: DockPreferencesReading {
    private static let domain = "com.apple.dock" as CFString
    private static let persistentAppsKey = "persistent-apps" as CFString

    func readEntries() throws -> [DockPreferenceEntry] {
        _ = CFPreferencesSynchronize(
            Self.domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )

        guard let value = CFPreferencesCopyValue(
            Self.persistentAppsKey,
            Self.domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else {
            throw DockPreferencesError.unavailable
        }

        guard let rows = value as? [[String: Any]] else {
            throw DockPreferencesError.invalidRoot
        }

        return Self.parse(rows: rows)
    }

    static func parse(rows: [[String: Any]]) -> [DockPreferenceEntry] {
        rows.enumerated().compactMap { index, row in
            let tileType = row["tile-type"] as? String
            if let tileType, tileType != "file-tile" {
                return nil
            }

            guard let tileData = row["tile-data"] as? [String: Any] else {
                return nil
            }

            let bundleIdentifier = nonEmptyString(tileData["bundle-identifier"])
            let fallbackName = nonEmptyString(tileData["file-label"])
            let bookmarkData = tileData["book"] as? Data
            let primaryURL = parseFileURL(from: tileData["file-data"])

            guard bundleIdentifier != nil || primaryURL != nil || bookmarkData != nil else {
                return nil
            }

            return DockPreferenceEntry(
                bundleIdentifier: bundleIdentifier,
                primaryURL: primaryURL,
                bookmarkData: bookmarkData,
                fallbackName: fallbackName,
                sourceOrder: index
            )
        }
    }

    private static func parseFileURL(from rawValue: Any?) -> URL? {
        guard
            let fileData = rawValue as? [String: Any],
            let rawString = nonEmptyString(fileData["_CFURLString"])
        else {
            return nil
        }

        let url: URL?
        if rawString.lowercased().hasPrefix("file:") {
            url = URL(string: rawString)
        } else if URL(string: rawString)?.scheme != nil {
            return nil
        } else {
            url = URL(fileURLWithPath: (rawString as NSString).expandingTildeInPath)
        }

        guard let url, url.isFileURL else { return nil }
        return url.standardizedFileURL
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

protocol ApplicationMetadataResolving {
    func resolve(_ entry: DockPreferenceEntry) -> PinnedApplication?
    func finderApplication() -> PinnedApplication?
}

final class ApplicationMetadataResolver: ApplicationMetadataResolving {
    private let workspace: NSWorkspace
    private let fileManager: FileManager
    private let displayNameResolver: ApplicationDisplayNameResolver

    init(
        workspace: NSWorkspace = .shared,
        fileManager: FileManager = .default,
        displayNameResolver: ApplicationDisplayNameResolver = ApplicationDisplayNameResolver()
    ) {
        self.workspace = workspace
        self.fileManager = fileManager
        self.displayNameResolver = displayNameResolver
    }

    func resolve(_ entry: DockPreferenceEntry) -> PinnedApplication? {
        let candidateURLs = resolvedCandidateURLs(for: entry)

        for candidate in candidateURLs {
            guard let metadata = metadata(for: candidate, expectedBundleIdentifier: entry.bundleIdentifier) else {
                continue
            }
            return PinnedApplication(
                identity: ApplicationIdentity(
                    bundleIdentifier: metadata.bundleIdentifier ?? entry.bundleIdentifier,
                    applicationURL: metadata.url
                ),
                bundleIdentifier: metadata.bundleIdentifier ?? entry.bundleIdentifier,
                applicationURL: metadata.url,
                displayName: metadata.displayName ?? entry.fallbackName ?? metadata.url.deletingPathExtension().lastPathComponent,
                sourceOrder: entry.sourceOrder
            )
        }

        return nil
    }

    func finderApplication() -> PinnedApplication? {
        let bundleIdentifier = "com.apple.finder"
        let fallbackURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) ?? fallbackURL
        guard let metadata = metadata(for: url, expectedBundleIdentifier: bundleIdentifier) else { return nil }
        return PinnedApplication(
            identity: ApplicationIdentity(bundleIdentifier: bundleIdentifier, applicationURL: metadata.url),
            bundleIdentifier: bundleIdentifier,
            applicationURL: metadata.url,
            displayName: metadata.displayName ?? L10n.text("application.finder"),
            sourceOrder: -1
        )
    }

    private func resolvedCandidateURLs(for entry: DockPreferenceEntry) -> [URL] {
        var candidates: [URL] = []
        if let primaryURL = entry.primaryURL {
            candidates.append(primaryURL)
        }

        if let bookmarkData = entry.bookmarkData {
            var isStale = false
            if let bookmarkURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                candidates.append(bookmarkURL)
            }
        }

        if let bundleIdentifier = entry.bundleIdentifier,
           let locatedURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            candidates.append(locatedURL)
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func metadata(
        for url: URL,
        expectedBundleIdentifier: String?
    ) -> (url: URL, bundleIdentifier: String?, displayName: String?)? {
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        guard resolvedURL.pathExtension.lowercased() == "app", let bundle = Bundle(url: resolvedURL) else {
            return nil
        }

        let actualIdentifier = bundle.bundleIdentifier
        if let expectedBundleIdentifier, let actualIdentifier,
           expectedBundleIdentifier.caseInsensitiveCompare(actualIdentifier) != .orderedSame {
            return nil
        }

        let displayName = displayNameResolver.displayName(for: resolvedURL, bundle: bundle)

        return (resolvedURL, actualIdentifier, displayName)
    }
}
