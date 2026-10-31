import AppKit
import QuartzCore
import Testing
@testable import EchoDock

@MainActor
struct DockPanelPresentationTests {
    @Test
    func windowResizeDoesNotReplaceThePreparedRevealPose() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 72))
        let presentation = DockPanelPresentationView(presentedView: content)
        let panel = DockPanel()
        panel.contentView = presentation
        panel.setFrame(NSRect(x: 0, y: 0, width: 240, height: 72), display: false)

        presentation.prepareForReveal(animated: true, reduceMotion: false)
        panel.setFrame(NSRect(x: 0, y: 0, width: 300, height: 100), display: false)
        presentation.layoutSubtreeIfNeeded()

        #expect(panel.contentView === presentation)
        #expect(content.superview === presentation)
        #expect(content.frame.origin == .zero)
        #expect(presentation.layer?.sublayerTransform.m42 == -72)
        #expect(presentation.layer?.opacity == 0)
    }

    @Test
    func animatedRevealHasARealPositionAndOpacityTransition() throws {
        let (panel, presentation, _) = makeVisiblePresentation()
        defer { presentation.reset(); panel.orderOut(nil) }
        presentation.prepareForReveal(animated: true, reduceMotion: false)
        var completed = false
        presentation.setVisible(true, animated: true, reduceMotion: false) { completed = true }

        let layer = try #require(presentation.layer)
        let animations = propertyAnimations(in: layer)
        #expect(animations.contains { $0.keyPath == "sublayerTransform" })
        #expect(animations.contains { $0.keyPath == "opacity" })
        #expect(!completed)
    }

    @Test
    func hideIsTheRevealAnimationPlayedBackward() throws {
        let (panel, presentation, _) = makeVisiblePresentation()
        defer { presentation.reset(); panel.orderOut(nil) }
        presentation.prepareForReveal(animated: true, reduceMotion: false)
        presentation.setVisible(true, animated: true, reduceMotion: false) {}
        let layer = try #require(presentation.layer)
        let reveal = try #require(animationGroup(in: layer))
        let revealProperties = propertyAnimations(in: layer)

        presentation.reset()
        presentation.setVisible(false, animated: true, reduceMotion: false) {}
        let hide = try #require(animationGroup(in: layer))
        let hideProperties = propertyAnimations(in: layer)

        #expect(hide.duration == reveal.duration)
        for property in ["sublayerTransform", "opacity"] {
            let forward = try #require(revealProperties.first { $0.keyPath == property })
            let backward = try #require(hideProperties.first { $0.keyPath == property })
            #expect((forward.fromValue as? NSObject)?.isEqual(backward.toValue) == true)
            #expect((forward.toValue as? NSObject)?.isEqual(backward.fromValue) == true)
        }

        let forwardCurve = try #require(reveal.timingFunction)
        let backwardCurve = try #require(hide.timingFunction)
        for index in [1, 2] {
            var forwardPoint: [Float] = [0, 0]
            var backwardPoint: [Float] = [0, 0]
            forwardCurve.getControlPoint(at: index, values: &forwardPoint)
            backwardCurve.getControlPoint(at: 3 - index, values: &backwardPoint)
            #expect(abs(backwardPoint[0] - (1 - forwardPoint[0])) < 0.000_1)
            #expect(abs(backwardPoint[1] - (1 - forwardPoint[1])) < 0.000_1)
        }
    }

    @Test
    func hidingKeepsTheContentInsideAppKitLayoutUntilTheTransitionFinishes() async throws {
        let (panel, presentation, content) = makeVisiblePresentation()
        defer { presentation.reset(); panel.orderOut(nil) }
        var completed = false
        presentation.setVisible(false, animated: true, reduceMotion: false) {
            completed = true
            panel.orderOut(nil)
        }

        // AppKit must keep drawing the view while the compositor slides it out.
        // Moving its NSView frame outside the parent culls native glass early.
        #expect(content.frame.origin == .zero)
        #expect(!content.visibleRect.isEmpty)
        #expect(presentation.layer?.sublayerTransform.m42 == -content.frame.height)
        #expect(presentation.layer?.animationKeys()?.isEmpty == false)
        #expect(panel.isVisible)
        #expect(!completed)
        #expect(try await eventually { completed })
        #expect(!panel.isVisible)
    }

    @Test
    func reducedMotionUsesOpacityWithoutSliding() throws {
        let (panel, presentation, content) = makeVisiblePresentation()
        defer { presentation.reset(); panel.orderOut(nil) }
        presentation.prepareForReveal(animated: true, reduceMotion: true)
        #expect(content.frame.origin == .zero)
        #expect(presentation.layer?.opacity == 0)
        presentation.setVisible(true, animated: true, reduceMotion: true) {}

        let layer = try #require(presentation.layer)
        let animations = propertyAnimations(in: layer)
        #expect(!animations.contains { $0.keyPath == "sublayerTransform" })
        #expect(animations.contains { $0.keyPath == "opacity" })
    }

    @Test
    func reversingAHideDoesNotRunItsObsoleteCompletion() async throws {
        let (panel, presentation, content) = makeVisiblePresentation()
        defer { presentation.reset(); panel.orderOut(nil) }
        var hideCompleted = false
        var revealCompleted = false
        presentation.setVisible(false, animated: true, reduceMotion: false) { hideCompleted = true }
        try await Task.sleep(for: .milliseconds(30))
        presentation.setVisible(true, animated: true, reduceMotion: false) { revealCompleted = true }

        #expect(try await eventually { revealCompleted })
        #expect(!hideCompleted)
        #expect(content.frame.origin == .zero)
        #expect(presentation.layer?.opacity == 1)
        #expect(presentation.layer?.sublayerTransform.m42 == 0)
    }

    @Test
    func immediateSuppressionCancelsAnInFlightReveal() async throws {
        let (panel, presentation, content) = makeVisiblePresentation()
        defer { presentation.reset(); panel.orderOut(nil) }
        var revealCompleted = false
        presentation.prepareForReveal(animated: true, reduceMotion: false)
        presentation.setVisible(true, animated: true, reduceMotion: false) { revealCompleted = true }
        presentation.reset()
        panel.orderOut(nil)
        try await Task.sleep(for: .milliseconds(250))

        #expect(!revealCompleted)
        #expect(!panel.isVisible)
        #expect(content.frame.origin == .zero)
        #expect(presentation.layer?.opacity == 1)
        #expect(presentation.layer?.animationKeys()?.isEmpty != false)
    }

    @Test
    func enablingIdleHidingSlidesOutBeforeOrderingTheWindowOut() async throws {
        let suite = "DockPanelPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.autoHide = false
        preferences.magnificationEnabled = false
        let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = DockPanelController(
            descriptor: DisplayDescriptor(
                identity: DisplayIdentity(rawValue: suite), displayID: 0,
                localizedName: "Test display",
                frame: CGRect(x: 10_000, y: -900, width: 1_440, height: 900),
                isMain: false, isBuiltIn: false, mirroredDisplayID: nil
            ),
            preferences: preferences,
            onItemAction: { _ in }, onItemContextAction: { _, _ in },
            contextMenuStateProvider: { _ in .unavailable }, onDropRequest: { _ in false }
        )
        defer { controller.destroy() }
        controller.applyPreferences()
        let panel = try #require(NSApp.windows.first {
            !previousWindows.contains(ObjectIdentifier($0)) && $0.contentView is DockPanelPresentationView
        })
        let presentation = try #require(panel.contentView as? DockPanelPresentationView)
        #expect(try await eventually { presentation.layer?.animationKeys()?.isEmpty != false })

        preferences.autoHide = true
        controller.applyPreferences()
        #expect(panel.isVisible)
        #expect(presentation.layer?.animationKeys()?.isEmpty == false)
        #expect(try await eventually { !panel.isVisible })
    }

    @Test
    func nonanimatedRevealCompletesImmediately() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 72))
        let presentation = DockPanelPresentationView(presentedView: content)
        presentation.prepareForReveal(animated: false, reduceMotion: false)
        var completed = false
        presentation.setVisible(true, animated: false, reduceMotion: false) { completed = true }
        #expect(completed)
        #expect(content.frame.origin == .zero)
        #expect(presentation.layer?.opacity == 1)
    }

    private func makeVisiblePresentation() -> (DockPanel, DockPanelPresentationView, NSView) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        content.wantsLayer = true
        let presentation = DockPanelPresentationView(presentedView: content)
        let panel = DockPanel()
        panel.ignoresMouseEvents = true
        panel.contentView = presentation
        panel.setFrame(NSRect(x: 20, y: 40, width: 80, height: 24), display: false)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        CATransaction.flush()
        return (panel, presentation, content)
    }

    private func propertyAnimations(in layer: CALayer) -> [CABasicAnimation] {
        (layer.animationKeys() ?? []).flatMap { key in
            let animation = layer.animation(forKey: key)
            if let group = animation as? CAAnimationGroup {
                return group.animations?.compactMap { $0 as? CABasicAnimation } ?? []
            }
            return (animation as? CABasicAnimation).map { [$0] } ?? []
        }
    }

    private func animationGroup(in layer: CALayer) -> CAAnimationGroup? {
        (layer.animationKeys() ?? []).compactMap {
            layer.animation(forKey: $0) as? CAAnimationGroup
        }.first
    }

    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
