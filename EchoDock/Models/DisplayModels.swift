import AppKit
import CoreGraphics

struct DisplayIdentity: Hashable, Codable, Sendable {
    let rawValue: String
}

struct DisplayDescriptor: Equatable {
    let identity: DisplayIdentity
    let displayID: CGDirectDisplayID
    let localizedName: String
    let frame: CGRect
    let isMain: Bool
    let isBuiltIn: Bool
    let mirroredDisplayID: CGDirectDisplayID?

    var isMirrorSecondary: Bool {
        mirroredDisplayID != nil
    }
}

enum NativeDockStrategy: String, Codable, CaseIterable {
    case systemManaged
    case fixedToSelectedDisplay
}

enum NativeDockSetupState: String, Codable {
    case systemManaged
    case waitingForConfiguration
    case waitingForLogin
    case waitingForAccessibility
    case relocating
    case fixed
    case targetOffline
    case invalid
    case unavailable
}

/// Converts the currently observable display/session facts into the persisted
/// native Dock setup state. The session notification is only a prompt to run
/// this evaluation again; it is never treated as proof that the setting took
/// effect.
enum NativeDockPolicyStateMachine {
    static func evaluate(
        strategy: NativeDockStrategy,
        hasTarget: Bool,
        targetIsAvailable: Bool,
        targetIsEligible: Bool,
        targetIsMain: Bool,
        screensHaveSeparateSpaces: Bool,
        lockStatus: NativeDockLockStatus
    ) -> NativeDockSetupState {
        guard strategy == .fixedToSelectedDisplay else {
            return .systemManaged
        }
        guard hasTarget else {
            return .waitingForConfiguration
        }
        guard targetIsAvailable else {
            return .targetOffline
        }
        guard targetIsEligible else {
            return .invalid
        }
        guard targetIsMain || screensHaveSeparateSpaces else {
            return .waitingForLogin
        }

        switch lockStatus {
        case .waitingForAccessibility:
            return .waitingForAccessibility
        case .relocating:
            return .relocating
        case .active:
            return .fixed
        case .targetUnavailable:
            return .targetOffline
        case .verificationFailed, .unavailable:
            return .unavailable
        case .disabled:
            return .waitingForConfiguration
        }
    }
}

/// The fixed-mode assignment that is ready to be committed after confirmation.
/// Keeping this as a value type makes the confirmation path side-effect free.
struct NativeDockAssignmentPlan: Equatable {
    let target: DisplayIdentity
    let displayOverrides: [DisplayIdentity: Bool]
}

enum NativeDockAssignmentPlanner {
    static func fixed(
        target: DisplayIdentity,
        displays: [DisplayDescriptor]
    ) -> NativeDockAssignmentPlan {
        var overrides: [DisplayIdentity: Bool] = [:]
        for display in displays where !display.isMirrorSecondary {
            overrides[display.identity] = display.identity != target
        }
        return NativeDockAssignmentPlan(target: target, displayOverrides: overrides)
    }
}
