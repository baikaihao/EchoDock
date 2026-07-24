import Foundation

extension Notification.Name {
    static let echoDockPreferencesDidChange = Notification.Name("EchoDock.preferencesDidChange")
    static let echoDockDisplayAssignmentsDidChange = Notification.Name("EchoDock.displayAssignmentsDidChange")
    static let echoDockDisplayTopologyDidChange = Notification.Name("EchoDock.displayTopologyDidChange")
    static let echoDockNativeDockLockStatusDidChange = Notification.Name("EchoDock.nativeDockLockStatusDidChange")
    static let echoDockOpenSettingsRequest = Notification.Name("EchoDock.openSettingsRequest")
    static let echoDockShowAboutRequest = Notification.Name("EchoDock.showAboutRequest")
    static let echoDockQuitRequest = Notification.Name("EchoDock.quitRequest")
}
