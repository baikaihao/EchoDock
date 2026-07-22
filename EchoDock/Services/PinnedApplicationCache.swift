import Foundation

final class PinnedApplicationCache {
    private struct Payload: Codable {
        let version: Int
        let applications: [PinnedApplication]
    }

    private let defaults: UserDefaults
    private let displayNameResolver: ApplicationDisplayNameResolver
    private let key = "lastValidPinnedApplications"

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
              payload.version == 1 else {
            return nil
        }
        return payload.applications.map(displayNameResolver.relocalize)
    }

    func save(_ applications: [PinnedApplication]) {
        let payload = Payload(version: 1, applications: applications)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: key)
    }
}
