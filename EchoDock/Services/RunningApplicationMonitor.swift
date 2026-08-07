import AppKit

@MainActor
protocol RunningApplicationMonitoring: AnyObject {
    var onChange: (() -> Void)? { get set }
    var onApplicationWillLaunch: ((ApplicationIdentity) -> Void)? { get set }
    var records: [RunningApplicationRecord] { get }

    func start()
    func stop()
    func reconcile()
    func instances(for identity: ApplicationIdentity) -> [NSRunningApplication]
}

@MainActor
final class RunningApplicationMonitor: NSObject, RunningApplicationMonitoring {
    var onChange: (() -> Void)?
    var onApplicationWillLaunch: ((ApplicationIdentity) -> Void)?

    private let workspace: NSWorkspace
    private let displayNameResolver: ApplicationDisplayNameResolver
    private var observers: [NSObjectProtocol] = []
    private var reconcileWorkItem: DispatchWorkItem?
    private var orderByIdentity: [ApplicationIdentity: Int] = [:]
    private var nextOrder = 0
    private var instancesByIdentity: [ApplicationIdentity: [NSRunningApplication]] = [:]
    private(set) var records: [RunningApplicationRecord] = []

    init(
        workspace: NSWorkspace = .shared,
        displayNameResolver: ApplicationDisplayNameResolver = ApplicationDisplayNameResolver()
    ) {
        self.workspace = workspace
        self.displayNameResolver = displayNameResolver
        super.init()
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = workspace.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.willLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let identity = Self.applicationIdentity(from: notification) else { return }
                self?.onApplicationWillLaunch?(identity)
            }
        })

        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]

        observers.append(contentsOf: names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleReconcile() }
            }
        })
        reconcile()
    }

    static func applicationIdentity(from notification: Notification) -> ApplicationIdentity? {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else {
            return nil
        }
        let identity = ApplicationIdentity(
            bundleIdentifier: application.bundleIdentifier,
            applicationURL: application.bundleURL
        )
        return identity.rawValue == "unknown" ? nil : identity
    }

    func stop() {
        reconcileWorkItem?.cancel()
        reconcileWorkItem = nil
        let center = workspace.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        records = []
        instancesByIdentity = [:]
        orderByIdentity = [:]
        nextOrder = 0
    }

    func instances(for identity: ApplicationIdentity) -> [NSRunningApplication] {
        instancesByIdentity[identity] ?? []
    }

    func reconcile() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates = workspace.runningApplications.filter { application in
            !application.isTerminated
                && application.processIdentifier != ownPID
                && application.activationPolicy == .regular
        }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            switch (lhs.launchDate, rhs.launchDate) {
            case let (left?, right?):
                if left != right { return left < right }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return lhs.localizedName ?? "" < rhs.localizedName ?? ""
        }

        var grouped: [ApplicationIdentity: [NSRunningApplication]] = [:]
        for application in sortedCandidates {
            let identity = ApplicationIdentity(
                bundleIdentifier: application.bundleIdentifier,
                applicationURL: application.bundleURL
            )
            guard identity.rawValue != "unknown" else { continue }
            grouped[identity, default: []].append(application)
            if orderByIdentity[identity] == nil {
                orderByIdentity[identity] = nextOrder
                nextOrder += 1
            }
        }

        orderByIdentity = orderByIdentity.filter { grouped[$0.key] != nil }
        instancesByIdentity = grouped
        records = grouped.compactMap { identity, applications in
            let representative = preferredRepresentative(from: applications)
            guard let applicationURL = representative.bundleURL
                ?? representative.bundleIdentifier.flatMap(workspace.urlForApplication(withBundleIdentifier:)) else {
                return nil
            }
            return RunningApplicationRecord(
                identity: identity,
                bundleIdentifier: representative.bundleIdentifier,
                applicationURL: applicationURL,
                displayName: displayNameResolver.displayName(
                    for: applicationURL,
                    fallbackName: representative.localizedName
                ),
                isActive: applications.contains(where: \.isActive),
                isHidden: applications.allSatisfy(\.isHidden),
                stableOrder: orderByIdentity[identity] ?? .max
            )
        }
        .sorted { $0.stableOrder < $1.stableOrder }

        onChange?()
    }

    private func preferredRepresentative(from applications: [NSRunningApplication]) -> NSRunningApplication {
        applications.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.isHidden != rhs.isHidden { return !lhs.isHidden }
            return (lhs.launchDate ?? .distantFuture) < (rhs.launchDate ?? .distantFuture)
        }.first!
    }

    private func scheduleReconcile() {
        reconcileWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.reconcile()
        }
        reconcileWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }
}
