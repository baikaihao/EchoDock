import AppKit

final class ApplicationIconProvider {
    static let shared = ApplicationIconProvider()

    private let cache = NSCache<NSString, NSImage>()

    func icon(for applicationURL: URL, size: CGFloat) -> NSImage {
        let cacheKey = "\(applicationURL.path)#\(Int(size))" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let image = loadIcon(at: applicationURL, size: size)
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    private func loadIcon(at url: URL, size: CGFloat) -> NSImage {
        let source = NSWorkspace.shared.icon(forFile: url.path)
        let image = (source.copy() as? NSImage) ?? source
        image.size = NSSize(width: size, height: size)
        return image
    }
}
