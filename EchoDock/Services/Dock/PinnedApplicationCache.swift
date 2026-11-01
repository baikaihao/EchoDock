import Foundation

protocol PinnedApplicationCaching {
    func load() -> [PinnedApplication]?
    func save(_ applications: [PinnedApplication])
}

final class PinnedApplicationCache: PinnedApplicationCaching {
    private static let currentVersion = 2

    private struct Payload: Codable {
        let version: Int
        let applications: [PinnedApplication]
    }

    private let defaults: UserDefaults
    private let displayNameResolver: ApplicationDisplayNameResolver
    private let key = "lastValidPinnedApplications"
    private var lastSavedApplications: [PinnedApplication]?

    init(
        defaults: UserDefaults = .standard,
        displayNameResolver: ApplicationDisplayNameResolver = ApplicationDisplayNameResolver()
    ) {
        self.defaults = defaults
        self.displayNameResolver = displayNameResolver
    }

    func load() -> [PinnedApplication]? {
        guard let data = defaults.data(forKey: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              (1...Self.currentVersion).contains(payload.version) else {
            return nil
        }
        let applications = payload.applications.map { application in
            let relocalized = displayNameResolver.relocalize(application)
            return PinnedApplication(
                identity: ApplicationIdentity(
                    bundleIdentifier: relocalized.bundleIdentifier,
                    applicationURL: relocalized.applicationURL
                ),
                bundleIdentifier: relocalized.bundleIdentifier,
                applicationURL: relocalized.applicationURL,
                displayName: relocalized.displayName,
                sourceOrder: relocalized.sourceOrder
            )
        }
        lastSavedApplications = payload.version == Self.currentVersion ? payload.applications : nil
        if payload.version < Self.currentVersion {
            save(applications)
        }
        return applications
    }

    func save(_ applications: [PinnedApplication]) {
        guard applications != lastSavedApplications else { return }
        let payload = Payload(
            version: Self.currentVersion,
            applications: applications
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: key)
        lastSavedApplications = applications
    }
}
