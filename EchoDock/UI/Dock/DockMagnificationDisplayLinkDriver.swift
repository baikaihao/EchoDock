import AppKit
import QuartzCore

@available(macOS 14.0, *)
final class DockMagnificationDisplayLinkDriver: NSObject {
    weak var owner: DockStripView?
    private var displayLink: CADisplayLink!
    private var configuredFramesPerSecond: Int?

    init(view: NSView, owner: DockStripView) {
        self.owner = owner
        super.init()
        displayLink = view.displayLink(
            target: self,
            selector: #selector(displayLinkFired)
        )
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
    }

    func start(framesPerSecond: Int) {
        let framesPerSecond = max(1, framesPerSecond)
        if configuredFramesPerSecond != framesPerSecond {
            configuredFramesPerSecond = framesPerSecond
            let frameRate = Float(framesPerSecond)
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: frameRate,
                maximum: frameRate,
                preferred: frameRate
            )
        }
        displayLink.isPaused = false
    }

    func pause() {
        displayLink.isPaused = true
    }

    func invalidate() {
        displayLink.invalidate()
    }

    @objc func displayLinkFired(_ displayLink: CADisplayLink) {
        owner?.advanceMagnificationFrame()
    }
}

