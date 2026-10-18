import AppKit
import XCTest
@testable import EchoDock

final class DockTooltipCanvasTests: XCTestCase {
    func testVisibleCanvasIsReusedWhileBubbleRemainsInside() {
        let canvas = NSRect(x: 100, y: 200, width: 400, height: 240)
        let bubble = NSRect(x: 220, y: 280, width: 120, height: 64)

        let layout = DockTooltipCanvasLayout.make(
            bubbleScreenFrame: bubble,
            currentCanvasFrame: canvas,
            screenFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
            keepsCurrentCanvas: true
        )

        XCTAssertEqual(layout.canvasFrame, canvas)
        XCTAssertEqual(
            layout.bubbleFrameInCanvas,
            NSRect(x: 120, y: 80, width: 120, height: 64)
        )
    }

    func testCanvasRecentersOnlyAfterBubbleLeavesIt() {
        let currentCanvas = NSRect(x: 100, y: 200, width: 300, height: 220)
        let bubble = NSRect(x: 700, y: 300, width: 120, height: 64)

        let layout = DockTooltipCanvasLayout.make(
            bubbleScreenFrame: bubble,
            currentCanvasFrame: currentCanvas,
            screenFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
            keepsCurrentCanvas: true
        )

        XCTAssertNotEqual(layout.canvasFrame, currentCanvas)
        XCTAssertTrue(layout.canvasFrame.contains(bubble))
        XCTAssertEqual(
            layout.bubbleFrameInCanvas.offsetBy(
                dx: layout.canvasFrame.minX,
                dy: layout.canvasFrame.minY
            ),
            bubble
        )
    }

    func testHiddenTooltipBuildsFreshCanvasAroundNextBubble() {
        let staleCanvas = NSRect(x: 100, y: 200, width: 400, height: 240)
        let bubble = NSRect(x: 220, y: 280, width: 120, height: 64)

        let layout = DockTooltipCanvasLayout.make(
            bubbleScreenFrame: bubble,
            currentCanvasFrame: staleCanvas,
            screenFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
            keepsCurrentCanvas: false
        )

        XCTAssertNotEqual(layout.canvasFrame, staleCanvas)
        XCTAssertEqual(layout.canvasFrame.midX, bubble.midX, accuracy: 0.001)
        XCTAssertEqual(layout.canvasFrame.midY, bubble.midY, accuracy: 0.001)
    }
}
