import AppKit

@MainActor
final class PreferencesStore {
    static let shared = PreferencesStore()

    private enum Key {
        static let isEnabled = "isEnabled"
        static let autoHide = "autoHide"
        static let reserveSpaceForWindows = "reserveSpaceForWindows"
        static let iconSize = "iconSize"
        static let iconSpacing = "iconSpacing"
        static let dockTransparency = "dockTransparency"
        static let dockBackgroundStyle = "dockBackgroundStyle"
        static let magnificationEnabled = "magnificationEnabled"
        static let magnificationScale = "magnificationScale"
        static let magnificationRange = "magnificationRange"
        static let tooltipGap = "tooltipGap"
        static let launchBounceEnabled = "launchBounceEnabled"
        static let runningIndicatorsEnabled = "runningIndicatorsEnabled"
        static let hideDelay = "hideDelay"
        static let internalEdgeDelay = "internalEdgeDelay"
        static let showRunningApplications = "showRunningApplications"
        static let displayOverrides = "displayOverrides"
        static let knownDisplays = "knownDisplays"
        static let newDisplaysEnabled = "newDisplaysEnabled"
        static let nativeDockStrategy = "nativeDockStrategy"
        static let nativeDockTarget = "nativeDockTarget"
        static let nativeDockSetupState = "nativeDockSetupState"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.isEnabled: true,
            Key.autoHide: false,
            Key.reserveSpaceForWindows: false,
            Key.iconSize: 48.0,
            Key.iconSpacing: 5.2,
            Key.dockTransparency: 0.17,
            Key.dockBackgroundStyle: DockBackgroundStyle.liquidGlass.rawValue,
            Key.magnificationEnabled: true,
            Key.magnificationScale: 1.18,
            Key.magnificationRange: 3.0,
            Key.tooltipGap: 4.0,
            Key.launchBounceEnabled: true,
            Key.runningIndicatorsEnabled: true,
            Key.hideDelay: 0.6,
            Key.internalEdgeDelay: 0.2,
            Key.showRunningApplications: true,
            Key.newDisplaysEnabled: true,
            Key.nativeDockStrategy: NativeDockStrategy.systemManaged.rawValue,
            Key.nativeDockSetupState: NativeDockSetupState.systemManaged.rawValue
        ])
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.isEnabled) }
        set { set(newValue, forKey: Key.isEnabled) }
    }

    var autoHide: Bool {
        get { defaults.bool(forKey: Key.autoHide) }
        set { set(newValue, forKey: Key.autoHide) }
    }

    var reserveSpaceForWindows: Bool {
        get { defaults.bool(forKey: Key.reserveSpaceForWindows) }
        set { set(newValue, forKey: Key.reserveSpaceForWindows) }
    }

    var iconSize: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.iconSize)).clamped(to: 32...64) }
        set { set(Double(newValue.clamped(to: 32...64)), forKey: Key.iconSize) }
    }

    /// Horizontal distance between adjacent application icon slots.
    var iconSpacing: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.iconSpacing)).clamped(to: 4...28) }
        set { set(Double(newValue.clamped(to: 4...28)), forKey: Key.iconSpacing) }
    }

    /// User-facing transparency: larger values produce a more transparent
    /// background while icons and interaction affordances remain fully opaque.
    var dockTransparency: CGFloat {
        get { DockBackgroundTransparency.clamped(CGFloat(defaults.double(forKey: Key.dockTransparency))) }
        set { set(Double(DockBackgroundTransparency.clamped(newValue)), forKey: Key.dockTransparency) }
    }

    var dockBackgroundStyle: DockBackgroundStyle {
        get {
            DockBackgroundStyle(
                rawValue: defaults.string(forKey: Key.dockBackgroundStyle) ?? ""
            ) ?? .liquidGlass
        }
        set { set(newValue.rawValue, forKey: Key.dockBackgroundStyle) }
    }

    var magnificationEnabled: Bool {
        get { defaults.bool(forKey: Key.magnificationEnabled) }
        set { set(newValue, forKey: Key.magnificationEnabled) }
    }

    /// Maximum icon scale at the pointer's center.
    var magnificationScale: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.magnificationScale)).clamped(to: 1.10...1.80) }
        set { set(Double(newValue.clamped(to: 1.10...1.80)), forKey: Key.magnificationScale) }
    }

    /// Radius of the magnification curve, measured in icon-slot widths.
    var magnificationRange: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.magnificationRange)).clamped(to: 1.25...3.50) }
        set { set(Double(newValue.clamped(to: 1.25...3.50)), forKey: Key.magnificationRange) }
    }

    /// Vertical clearance between the Dock and the application-name bubble.
    var tooltipGap: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.tooltipGap)).clamped(to: 0...24) }
        set { set(Double(newValue.clamped(to: 0...24)), forKey: Key.tooltipGap) }
    }

    var launchBounceEnabled: Bool {
        get { defaults.bool(forKey: Key.launchBounceEnabled) }
        set { set(newValue, forKey: Key.launchBounceEnabled) }
    }

    var runningIndicatorsEnabled: Bool {
        get { defaults.bool(forKey: Key.runningIndicatorsEnabled) }
        set { set(newValue, forKey: Key.runningIndicatorsEnabled) }
    }

    func restoreAppearanceDefaults() {
        [
            Key.iconSize,
            Key.iconSpacing,
            Key.dockTransparency,
            Key.dockBackgroundStyle,
            Key.magnificationEnabled,
            Key.magnificationScale,
            Key.magnificationRange,
            Key.tooltipGap,
            Key.launchBounceEnabled,
            Key.runningIndicatorsEnabled
        ].forEach(defaults.removeObject(forKey:))
        NotificationCenter.default.post(name: .echoDockPreferencesDidChange, object: self)
    }

    var hideDelay: TimeInterval {
        get { defaults.double(forKey: Key.hideDelay).clamped(to: 0.2...2.0) }
        set { set(newValue.clamped(to: 0.2...2.0), forKey: Key.hideDelay) }
    }

    var internalEdgeDelay: TimeInterval {
        get { defaults.double(forKey: Key.internalEdgeDelay).clamped(to: 0...0.5) }
        set { set(newValue.clamped(to: 0...0.5), forKey: Key.internalEdgeDelay) }
    }

    var showRunningApplications: Bool {
        get { defaults.bool(forKey: Key.showRunningApplications) }
        set { set(newValue, forKey: Key.showRunningApplications) }
    }

    var newDisplaysEnabled: Bool {
        get { defaults.bool(forKey: Key.newDisplaysEnabled) }
        set { set(newValue, forKey: Key.newDisplaysEnabled) }
    }

    var nativeDockStrategy: NativeDockStrategy {
        get {
            let rawValue = defaults.string(forKey: Key.nativeDockStrategy) ?? ""
            if rawValue == "fixedToSelectedMainDisplay" {
                defaults.set(
                    NativeDockStrategy.fixedToSelectedDisplay.rawValue,
                    forKey: Key.nativeDockStrategy
                )
                return .fixedToSelectedDisplay
            }
            return NativeDockStrategy(rawValue: rawValue) ?? .systemManaged
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.nativeDockStrategy)
            if newValue == .systemManaged {
                defaults.set(NativeDockSetupState.systemManaged.rawValue, forKey: Key.nativeDockSetupState)
            } else if nativeDockSetupState == .systemManaged {
                defaults.set(NativeDockSetupState.waitingForConfiguration.rawValue, forKey: Key.nativeDockSetupState)
            }
            notifyDisplayChange()
        }
    }

    var nativeDockTarget: DisplayIdentity? {
        get {
            guard let value = defaults.string(forKey: Key.nativeDockTarget), !value.isEmpty else { return nil }
            return DisplayIdentity(rawValue: value)
        }
        set {
            defaults.set(newValue?.rawValue, forKey: Key.nativeDockTarget)
            notifyDisplayChange()
        }
    }

    var nativeDockSetupState: NativeDockSetupState {
        get {
            NativeDockSetupState(rawValue: defaults.string(forKey: Key.nativeDockSetupState) ?? "") ?? .systemManaged
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.nativeDockSetupState)
            notifyDisplayChange()
        }
    }

    func registerDisplays(_ displays: [DisplayDescriptor]) {
        var known = Set(defaults.stringArray(forKey: Key.knownDisplays) ?? [])
        var overrides = displayOverrides
        var changed = false

        for display in displays where !known.contains(display.identity.rawValue) {
            known.insert(display.identity.rawValue)
            overrides[display.identity.rawValue] = newDisplaysEnabled
            changed = true
        }

        guard changed else { return }
        defaults.set(Array(known).sorted(), forKey: Key.knownDisplays)
        defaults.set(overrides, forKey: Key.displayOverrides)
    }

    func isDisplayEnabled(_ identity: DisplayIdentity) -> Bool {
        displayOverrides[identity.rawValue] ?? newDisplaysEnabled
    }

    func displayEnabledMap(for displays: [DisplayDescriptor]) -> [DisplayIdentity: Bool] {
        displays.reduce(into: [DisplayIdentity: Bool]()) { result, display in
            result[display.identity] = isDisplayEnabled(display.identity)
        }
    }

    func setDisplayEnabled(_ enabled: Bool, identity: DisplayIdentity) {
        var overrides = displayOverrides
        guard overrides[identity.rawValue] != enabled else { return }
        overrides[identity.rawValue] = enabled
        defaults.set(overrides, forKey: Key.displayOverrides)
        notifyDisplayChange()
    }

    /// Writes the fixed target and default per-display assignments together so
    /// observers never see a partially applied selection.
    func applyNativeDockTargetSelection(
        target: DisplayIdentity,
        displays: [DisplayDescriptor],
        resetDisplayAssignments: Bool
    ) {
        let plan = NativeDockAssignmentPlanner.fixed(target: target, displays: displays)
        let previousStrategy = nativeDockStrategy
        let previousTarget = nativeDockTarget
        var overrides = displayOverrides
        var changed = false

        if previousStrategy != .fixedToSelectedDisplay {
            defaults.set(NativeDockStrategy.fixedToSelectedDisplay.rawValue, forKey: Key.nativeDockStrategy)
            changed = true
        }
        if previousTarget != target {
            defaults.set(target.rawValue, forKey: Key.nativeDockTarget)
            changed = true
        }
        if nativeDockSetupState != .relocating {
            defaults.set(NativeDockSetupState.relocating.rawValue, forKey: Key.nativeDockSetupState)
            changed = true
        }

        if resetDisplayAssignments || previousTarget != target {
            for (identity, enabled) in plan.displayOverrides where overrides[identity.rawValue] != enabled {
                overrides[identity.rawValue] = enabled
                changed = true
            }
            defaults.set(overrides, forKey: Key.displayOverrides)
        }

        guard changed else { return }
        notifyDisplayChange()
    }

    private var displayOverrides: [String: Bool] {
        defaults.dictionary(forKey: Key.displayOverrides) as? [String: Bool] ?? [:]
    }

    private func set<T: Equatable>(_ value: T, forKey key: String) {
        if let current = defaults.object(forKey: key) as? T, current == value { return }
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .echoDockPreferencesDidChange, object: self)
    }

    private func notifyDisplayChange() {
        NotificationCenter.default.post(name: .echoDockDisplayAssignmentsDidChange, object: self)
        NotificationCenter.default.post(name: .echoDockPreferencesDidChange, object: self)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
