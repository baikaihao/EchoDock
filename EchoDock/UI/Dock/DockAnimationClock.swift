import Foundation

/// Allows geometry/interaction tests to advance frames independently of window
/// occlusion. Production views keep using their display-linked frame clock.
protocol DockAnimationClock: AnyObject {
    func start(framesPerSecond: Int, onFrame: @escaping () -> Void)
    func stop()
}
