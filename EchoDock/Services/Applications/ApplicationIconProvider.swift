import AppKit

final class ApplicationIconProvider {
    static let shared = ApplicationIconProvider()

    struct PreparedIcons {
        fileprivate let imagesByKey: [String: NSImage]
    }

    private static let renderPixelDimension = 256
    private static let renderedImageCost = renderPixelDimension * renderPixelDimension * 4
    private static let maximumCachedImageCount = 64
    private static let maximumMemoryCost = 16 * 1024 * 1024

    private struct Request {
        let url: URL
        let key: String
    }

    private let cache = NSCache<NSString, NSImage>()
    private let workspace: NSWorkspace
    private let priorityPrewarmQueue: OperationQueue
    private let stateLock = NSLock()
    private var inFlightLoads: [String: DispatchGroup] = [:]
    private var displayedImages: [String: NSImage] = [:]
    private var workspaceObserver: NSObjectProtocol?
    private var hasStarted = false

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace

        let priorityQueue = OperationQueue()
        priorityQueue.name = "com.baikaihao.EchoDock.icon-prewarm.priority"
        priorityQueue.qualityOfService = .userInitiated
        priorityQueue.maxConcurrentOperationCount = 1
        priorityPrewarmQueue = priorityQueue

        cache.name = "com.baikaihao.EchoDock.application-icons"
        cache.countLimit = Self.maximumCachedImageCount
        cache.totalCostLimit = Self.maximumMemoryCost
    }

    /// Observes launches so an arriving app can be decoded before its next
    /// Dock snapshot is presented. Snapshot preparation handles startup icons.
    func startObservingApplicationLaunches() {
        stateLock.lock()
        guard !hasStarted else {
            stateLock.unlock()
            return
        }
        hasStarted = true
        stateLock.unlock()

        let center = workspace.notificationCenter
        workspaceObserver = center.addObserver(
            forName: NSWorkspace.willLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  let url = application.bundleURL
                    ?? application.bundleIdentifier.flatMap(
                        self.workspace.urlForApplication(withBundleIdentifier:)
                    ) else {
                return
            }
            self.prepareIcons(for: [url])
        }
    }

    func stopObservingApplicationLaunches() {
        stateLock.lock()
        hasStarted = false
        let observer = workspaceObserver
        workspaceObserver = nil
        displayedImages.removeAll()
        stateLock.unlock()

        if let observer {
            workspace.notificationCenter.removeObserver(observer)
        }
        priorityPrewarmQueue.cancelAllOperations()
        cache.removeAllObjects()
    }

    /// Prepares a set of icons before a snapshot is presented. Completion is
    /// always delivered on the main queue after every icon is fully decoded.
    func prepareIcons(
        for applicationURLs: [URL],
        completion: ((PreparedIcons) -> Void)? = nil
    ) {
        let requests = uniqueRequests(for: applicationURLs)
        guard !requests.isEmpty else {
            if let completion {
                DispatchQueue.main.async {
                    completion(PreparedIcons(imagesByKey: [:]))
                }
            }
            return
        }

        let operation = BlockOperation { [weak self] in
            guard let self else { return }
            var images: [String: NSImage] = [:]
            for request in requests {
                autoreleasepool {
                    images[request.key] = self.cachedOrLoad(request)
                }
            }
            if let completion {
                DispatchQueue.main.async {
                    completion(PreparedIcons(imagesByKey: images))
                }
            }
        }
        operation.qualityOfService = .userInitiated
        operation.queuePriority = .veryHigh
        priorityPrewarmQueue.addOperation(operation)
    }

    func retainForDisplay(_ preparedIcons: PreparedIcons) {
        stateLock.lock()
        displayedImages = preparedIcons.imagesByKey
        stateLock.unlock()
    }

    func icon(for applicationURL: URL, size: CGFloat) -> NSImage {
        let request = request(for: applicationURL)
        stateLock.lock()
        let displayedImage = displayedImages[request.key]
        stateLock.unlock()
        let image = displayedImage ?? cachedOrLoad(request)
        guard size > 0 else { return image }

        // The NSImageView owns sizing. Keeping one decoded master image per
        // URL avoids creating a new cached copy for every slider value.
        return image
    }

    private func request(for url: URL) -> Request {
        let normalizedURL = url.standardizedFileURL
        return Request(
            url: normalizedURL,
            key: normalizedURL.path
        )
    }

    private func uniqueRequests(for urls: [URL]) -> [Request] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let request = request(for: url)
            return seen.insert(request.key).inserted ? request : nil
        }
    }

    private func cachedOrLoad(_ request: Request) -> NSImage {
        let cacheKey = request.key as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        stateLock.lock()
        if let displayedImage = displayedImages[request.key] {
            stateLock.unlock()
            cache.setObject(
                displayedImage,
                forKey: cacheKey,
                cost: Self.renderedImageCost
            )
            return displayedImage
        }
        if let existingLoad = inFlightLoads[request.key] {
            stateLock.unlock()
            existingLoad.wait()
            if let cached = cache.object(forKey: cacheKey) {
                return cached
            }
            return loadRasterizedIcon(at: request.url)
        }

        let loadGroup = DispatchGroup()
        loadGroup.enter()
        inFlightLoads[request.key] = loadGroup
        stateLock.unlock()

        let image = loadRasterizedIcon(at: request.url)
        cache.setObject(
            image,
            forKey: cacheKey,
            cost: Self.renderedImageCost
        )

        stateLock.lock()
        inFlightLoads.removeValue(forKey: request.key)
        loadGroup.leave()
        stateLock.unlock()
        return image
    }

    private func loadRasterizedIcon(at url: URL) -> NSImage {
        let source = workspace.icon(forFile: url.path)
        let pixels = Self.renderPixelDimension
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            let fallback = (source.copy() as? NSImage) ?? source
            fallback.size = NSSize(width: pixels, height: pixels)
            return fallback
        }

        let targetRect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(targetRect)
        context.imageInterpolation = .high
        source.draw(
            in: targetRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        bitmap.size = targetRect.size
        let image = NSImage(size: targetRect.size)
        image.addRepresentation(bitmap)
        image.isTemplate = source.isTemplate
        return image
    }
}
