import AppKit

struct DockRecycleResult: Equatable, Sendable {
    let recycledURLs: [URL: URL]
    let errorDescription: String?
}

@MainActor
final class DockFileOperator {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func recycle(
        _ fileURLs: [URL],
        completion: @escaping (DockRecycleResult) -> Void
    ) {
        let urls = uniqueFileURLs(fileURLs)
        guard !urls.isEmpty else {
            completion(DockRecycleResult(recycledURLs: [:], errorDescription: nil))
            return
        }

        let securityScopedURLs = urls.filter {
            $0.startAccessingSecurityScopedResource()
        }
        workspace.recycle(urls) { mappings, error in
            securityScopedURLs.forEach {
                $0.stopAccessingSecurityScopedResource()
            }
            DispatchQueue.main.async {
                completion(DockRecycleResult(
                    recycledURLs: mappings,
                    errorDescription: error?.localizedDescription
                ))
            }
        }
    }

    private func uniqueFileURLs(_ urls: [URL]) -> [URL] {
        var paths = Set<String>()
        return urls.compactMap { url in
            guard url.isFileURL else { return nil }
            let normalized = url.standardizedFileURL
            return paths.insert(normalized.path).inserted ? normalized : nil
        }
    }
}
