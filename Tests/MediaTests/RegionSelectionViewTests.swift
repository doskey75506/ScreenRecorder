import AppKit
import XCTest
@testable import ScreenRecorder

@MainActor
final class RegionSelectionViewTests: XCTestCase {
    private func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [],
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testDraggingAndReleasingConfirmsDisplayLocalRectangle() throws {
        let view = RegionSelectionView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelScale: 2)
        var selected: CGRect?
        view.onSelection = { selected = $0 }
        view.mouseDown(with: try event(.leftMouseDown, 50, 60))
        view.mouseDragged(with: try event(.leftMouseDragged, 450, 260))
        XCTAssertNil(selected)
        view.mouseUp(with: try event(.leftMouseUp, 450, 260))
        XCTAssertEqual(selected, CGRect(x: 50, y: 60, width: 400, height: 200))
    }

    func testClickWithoutDraggingDoesNotConfirmOrDismiss() throws {
        let view = RegionSelectionView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelScale: 2)
        var dismissed = false
        view.onSelection = { _ in dismissed = true }
        view.mouseDown(with: try event(.leftMouseDown, 50, 60))
        view.mouseUp(with: try event(.leftMouseUp, 50, 60))
        XCTAssertFalse(dismissed)
    }

    func testReverseDragStaysInsideItsDisplay() throws {
        let view = RegionSelectionView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelScale: 1)
        var selected: CGRect?
        view.onSelection = { selected = $0 }
        view.mouseDown(with: try event(.leftMouseDown, 100, 120))
        view.mouseUp(with: try event(.leftMouseUp, -30, -50))
        XCTAssertEqual(selected, CGRect(x: 0, y: 0, width: 100, height: 120))
    }

    func testEscapeAndRightClickCancelWithoutSelectingAnArea() throws {
        let view = RegionSelectionView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelScale: 2)
        var cancellations = 0
        view.onSelection = { rect in
            XCTAssertNil(rect)
            cancellations += 1
        }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: 0, context: nil,
                                                   characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                   isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        view.rightMouseDown(with: try event(.rightMouseDown, 100, 120))
        XCTAssertEqual(cancellations, 2)
    }
}
