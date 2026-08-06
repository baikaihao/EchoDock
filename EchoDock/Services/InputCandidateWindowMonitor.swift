import AppKit
import CoreGraphics

struct InputCandidateWindowSnapshot: Equatable {
    let bounds: CGRect
    let layer: Int
    let ownerProcessIdentifier: pid_t
    let isRegularApplication: Bool
    let alpha: CGFloat
    let isOnScreen: Bool
}

struct InputCandidateDockRegion: Equatable {
    let displayIdentity: DisplayIdentity
    let frame: CGRect
}

enum InputCandidateAvoidancePolicy {
    static func occludedDisplayIdentities(
        regions: [InputCandidateDockRegion],
        windows: [InputCandidateWindowSnapshot],
        excludingProcessIdentifier: pid_t,
        dockWindowLevel: Int = Int(CGWindowLevelForKey(.dockWindow))
    ) -> Set<DisplayIdentity> {
        guard dockWindowLevel > 1 else { return [] }
        let normalWindowLevel = Int(CGWindowLevelForKey(.normalWindow))

        let candidateWindows = windows.filter { window in
            window.isOnScreen
                && window.alpha > 0.01
                && window.ownerProcessIdentifier > 0
                && window.ownerProcessIdentifier != excludingProcessIdentifier
                && !window.isRegularApplication
                && window.layer > normalWindowLevel
                && window.layer < dockWindowLevel
                && isValid(window.bounds)
        }

        return Set(regions.compactMap { region in
            guard isValid(region.frame),
                  candidateWindows.contains(where: { window in
                    let intersection = window.bounds.intersection(region.frame)
                    return !intersection.isNull
                        && intersection.width > 0.5
                        && intersection.height > 0.5
                  }) else {
                return nil
            }
            return region.displayIdentity
        })
    }

    private static func isValid(_ frame: CGRect) -> Bool {
        frame.width > 0
            && frame.height > 0
            && frame.minX.isFinite
            && frame.minY.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
    }
}

struct InputCandidateOcclusionDebouncer {
    private(set) var occludedDisplayIdentities: Set<DisplayIdentity> = []

    private let missesRequiredToRestore: Int
    private var consecutiveMisses: [DisplayIdentity: Int] = [:]

    init(missesRequiredToRestore: Int = 2) {
        self.missesRequiredToRestore = max(1, missesRequiredToRestore)
    }

    mutating func accept(
        _ observedDisplayIdentities: Set<DisplayIdentity>
    ) -> Set<DisplayIdentity>? {
        var next = occludedDisplayIdentities

        for identity in observedDisplayIdentities {
            next.insert(identity)
            consecutiveMisses.removeValue(forKey: identity)
        }

        for identity in occludedDisplayIdentities.subtracting(observedDisplayIdentities) {
            let missCount = (consecutiveMisses[identity] ?? 0) + 1
            if missCount >= missesRequiredToRestore {
                next.remove(identity)
                consecutiveMisses.removeValue(forKey: identity)
            } else {
                consecutiveMisses[identity] = missCount
            }
        }

        guard next != occludedDisplayIdentities else { return nil }
        occludedDisplayIdentities = next
        return next
    }

    mutating func reset() {
        consecutiveMisses.removeAll()
        occludedDisplayIdentities.removeAll()
    }
}

private enum SystemInputCandidateWindowSnapshotProvider {
    static func currentSnapshots() -> [InputCandidateWindowSnapshot]? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else {
            return nil
        }

        let normalWindowLevel = Int(CGWindowLevelForKey(.normalWindow))
        let dockWindowLevel = Int(CGWindowLevelForKey(.dockWindow))
        var regularApplicationCache: [pid_t: Bool] = [:]
        return windowInfo.compactMap { info in
            guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  let layerNumber = info[kCGWindowLayer as String] as? NSNumber,
                  let ownerNumber = info[kCGWindowOwnerPID as String] as? NSNumber else {
                return nil
            }

            let layer = layerNumber.intValue
            guard layer > normalWindowLevel,
                  layer < dockWindowLevel else {
                return nil
            }

            let processIdentifier = pid_t(ownerNumber.int32Value)
            let isRegularApplication: Bool
            if let cached = regularApplicationCache[processIdentifier] {
                isRegularApplication = cached
            } else {
                isRegularApplication = NSRunningApplication(
                    processIdentifier: processIdentifier
                )?.activationPolicy == .regular
                regularApplicationCache[processIdentifier] = isRegularApplication
            }

            return InputCandidateWindowSnapshot(
                bounds: bounds,
                layer: layer,
                ownerProcessIdentifier: processIdentifier,
                isRegularApplication: isRegularApplication,
                alpha: CGFloat(
                    (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
                ),
                isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
            )
        }
    }
}

@MainActor
final class InputCandidateWindowMonitor: NSObject {
    typealias WindowSnapshotProvider = () -> [InputCandidateWindowSnapshot]?

    private static let refreshInterval: TimeInterval = 0.1

    var regionsProvider: () -> [InputCandidateDockRegion] = { [] }
    var onOccludedDisplaysChange: ((Set<DisplayIdentity>) -> Void)?

    private let currentProcessIdentifier: pid_t
    private let windowSnapshotProvider: WindowSnapshotProvider
    private let snapshotQueue = DispatchQueue(
        label: "com.baikaihao.EchoDock.input-candidate-windows",
        qos: .utility
    )
    private var timer: Timer?
    private var lifecycleGeneration: UInt64 = 0
    private var refreshGeneration: UInt64 = 0
    private var isRefreshInFlight = false
    private var requestedRegions: [InputCandidateDockRegion] = []
    private var debouncer = InputCandidateOcclusionDebouncer()

    init(
        currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        windowSnapshotProvider: @escaping WindowSnapshotProvider = {
            SystemInputCandidateWindowSnapshotProvider.currentSnapshots()
        }
    ) {
        self.currentProcessIdentifier = currentProcessIdentifier
        self.windowSnapshotProvider = windowSnapshotProvider
    }

    func start() {
        guard timer == nil else { return }
        lifecycleGeneration &+= 1
        let timer = Timer(
            timeInterval: Self.refreshInterval,
            target: self,
            selector: #selector(timerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        requestRefresh()
    }

    func stop() {
        lifecycleGeneration &+= 1
        refreshGeneration &+= 1
        timer?.invalidate()
        timer = nil
        isRefreshInFlight = false
        requestedRegions.removeAll()
        debouncer.reset()
    }

    func refreshNow() {
        guard timer != nil else { return }
        requestRefresh()
    }

    deinit {
        timer?.invalidate()
    }

    @objc private func timerFired() {
        requestRefresh()
    }

    private func requestRefresh() {
        let regions = currentRegions()
        if regions != requestedRegions {
            requestedRegions = regions
            refreshGeneration &+= 1
            isRefreshInFlight = false
        }
        guard !regions.isEmpty else {
            accept([])
            return
        }
        guard !isRefreshInFlight else { return }

        isRefreshInFlight = true
        refreshGeneration &+= 1
        let requestLifecycleGeneration = lifecycleGeneration
        let requestRefreshGeneration = refreshGeneration
        let provider = windowSnapshotProvider
        let currentProcessIdentifier = currentProcessIdentifier

        snapshotQueue.async { [weak self] in
            let windows = provider()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.lifecycleGeneration == requestLifecycleGeneration,
                      self.refreshGeneration == requestRefreshGeneration,
                      self.timer != nil else {
                    return
                }
                self.isRefreshInFlight = false
                guard let windows else { return }

                let latestRegions = self.currentRegions()
                self.requestedRegions = latestRegions
                let next = InputCandidateAvoidancePolicy.occludedDisplayIdentities(
                    regions: latestRegions,
                    windows: windows,
                    excludingProcessIdentifier: currentProcessIdentifier
                )
                self.accept(next)
            }
        }
    }

    private func accept(_ next: Set<DisplayIdentity>) {
        guard let accepted = debouncer.accept(next) else { return }
        onOccludedDisplaysChange?(accepted)
    }

    private func currentRegions() -> [InputCandidateDockRegion] {
        regionsProvider().sorted {
            $0.displayIdentity.rawValue < $1.displayIdentity.rawValue
        }
    }
}
