import XCTest
@testable import RecorderCore

final class CaptureRegionTests: XCTestCase {
    func testAppKitBottomLeftBecomesDisplayLocalTopLeft() throws {
        let region = try CaptureRegion(appKitRect: CGRect(x: 120, y: 100, width: 400, height: 300),
                                       displaySize: CGSize(width: 1440, height: 900), pixelScale: 1)
        XCTAssertEqual(region.sourceRect, CGRect(x: 120, y: 500, width: 400, height: 300))
        XCTAssertEqual(region.pixelSize, CGSize(width: 400, height: 300))
    }

    func testRetinaUsesPointsForCaptureAndPixelsForOutput() throws {
        let region = try CaptureRegion(appKitRect: CGRect(x: 120, y: 100, width: 400, height: 300),
                                       displaySize: CGSize(width: 1440, height: 900), pixelScale: 2)
        XCTAssertEqual(region.sourceRect, CGRect(x: 120, y: 500, width: 400, height: 300))
        XCTAssertEqual(region.pixelSize, CGSize(width: 800, height: 600))
    }

    func testFractionalSelectionRoundsInwardAndNeverCapturesOutsideTheBox() throws {
        let input = CGRect(x: 10.2, y: 20.3, width: 101.7, height: 80.4)
        let region = try CaptureRegion(appKitRect: input, displaySize: CGSize(width: 200, height: 150), pixelScale: 2)
        XCTAssertEqual(region.sourceRect, CGRect(x: 10.5, y: 49.5, width: 101, height: 80))
        XCTAssertEqual(region.pixelSize, CGSize(width: 202, height: 160))
        let originalTopLeft = CGRect(x: input.minX, y: 150 - input.maxY, width: input.width, height: input.height)
        XCTAssertTrue(originalTopLeft.contains(region.sourceRect))
    }

    func testReverseDragAndScreenEdgesAreClamped() throws {
        let region = try CaptureRegion(appKitRect: CGRect(x: 120, y: 90, width: -140, height: -100),
                                       displaySize: CGSize(width: 100, height: 80), pixelScale: 1)
        XCTAssertEqual(region.sourceRect, CGRect(x: 0, y: 0, width: 100, height: 80))
    }

    func testDisplayLocalCoordinatesDoNotIncludeOtherScreensGlobalOrigins() throws {
        // The picker converts mouse events into each panel's local coordinates.
        // A display left of or above the main display uses the same local crop.
        for origin in [CGPoint.zero, CGPoint(x: -1440, y: 200), CGPoint(x: 500, y: 900)] {
            let frame = CGRect(origin: origin, size: CGSize(width: 1440, height: 900))
            let desktopSelection = CGRect(x: frame.minX + 30, y: frame.minY + 40, width: 200, height: 100)
            let local = desktopSelection.offsetBy(dx: -frame.minX, dy: -frame.minY)
            let region = try CaptureRegion(appKitRect: local, displaySize: frame.size, pixelScale: 2)
            XCTAssertEqual(region.sourceRect, CGRect(x: 30, y: 760, width: 200, height: 100))
        }
    }

    func testEmptyOffscreenAndNonfiniteRegionsAreRejected() {
        let size = CGSize(width: 100, height: 80)
        for rect in [CGRect.zero, CGRect(x: 0, y: 0, width: 1, height: 1),
                     CGRect(x: 120, y: 90, width: 10, height: 10),
                     CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)] {
            XCTAssertThrowsError(try CaptureRegion(appKitRect: rect, displaySize: size, pixelScale: 1))
        }
        for scale in [CGFloat.zero, -1, .nan, .infinity] {
            XCTAssertThrowsError(try CaptureRegion(appKitRect: CGRect(x: 0, y: 0, width: 20, height: 20),
                                                  displaySize: size, pixelScale: scale))
        }
    }

    func testOutputResolutionUsesRegionSizeAndNeverUpscales() throws {
        let region = try CaptureRegion(appKitRect: CGRect(x: 0, y: 0, width: 800, height: 450),
                                       displaySize: CGSize(width: 1920, height: 1080), pixelScale: 2)
        XCTAssertEqual(CaptureResolution.native.outputSize(for: region.pixelSize), CGSize(width: 1600, height: 900))
        XCTAssertEqual(CaptureResolution.fullHD.outputSize(for: region.pixelSize), CGSize(width: 1600, height: 900))
        XCTAssertEqual(CaptureResolution.compact.outputSize(for: region.pixelSize), CGSize(width: 640, height: 360))
    }

    func testSelectingRegionBlocksStartingAndOtherSourceChanges() {
        XCTAssertTrue(RecordingPhase.selectingRegion.isBusy)
        XCTAssertFalse(RecordingPhase.selectingRegion.canStart)
        XCTAssertFalse(RecordingPhase.selectingRegion.canStop)
    }
}
