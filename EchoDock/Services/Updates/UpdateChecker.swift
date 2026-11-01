import Foundation

struct UpdateChecker {
    enum Result {
        case upToDate(currentVersion: String)
        case available(version: String, currentVersion: String, releaseURL: URL)
    }

    enum CheckError: Error {
        case invalidVersion
        case invalidResponse
        case noRelease
        case rateLimited
        case serverUnavailable
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft, prerelease
        }
    }

    private let session: URLSession
    private let currentVersion: String?

    init(session: URLSession = .shared, bundle: Bundle = .main) {
        self.session = session
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    func check() async throws -> Result {
        guard let currentVersion, let installed = AppVersion(currentVersion) else {
            throw CheckError.invalidVersion
        }
        let endpoint = URL(string: "https://api.github.com/repos/baikaihao/EchoDock/releases/latest")!
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("EchoDock/\(installed.displayValue)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw CheckError.invalidResponse
        }
        switch response.statusCode {
        case 200: break
        case 404: throw CheckError.noRelease
        case 403, 429: throw CheckError.rateLimited
        default: throw CheckError.serverUnavailable
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease,
              let latest = AppVersion(release.tagName),
              release.htmlURL.scheme == "https",
              release.htmlURL.host?.lowercased() == "github.com",
              release.htmlURL.user == nil,
              release.htmlURL.password == nil,
              release.htmlURL.port == nil,
              release.htmlURL.path.hasPrefix("/baikaihao/EchoDock/releases/tag/") else {
            throw CheckError.invalidResponse
        }
        if latest > installed {
            return .available(
                version: latest.displayValue,
                currentVersion: installed.displayValue,
                releaseURL: release.htmlURL
            )
        }
        return .upToDate(currentVersion: installed.displayValue)
    }
}
