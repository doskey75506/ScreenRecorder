import XCTest
import RecorderCore
@testable import ScreenRecorder

@MainActor
final class SourceSelectionModelTests: XCTestCase {
    func testLoadingDoesNotAutomaticallyChooseASource() async {
        let source = CaptureSourceOption(id: 1, title: "Screen")
        let model = SourceSelectionModel(mode: .display) { [source] }
        XCTAssertFalse(model.canConfirm)
        await model.refresh()
        XCTAssertEqual(model.options, [source])
        XCTAssertNil(model.selectedID)
        XCTAssertFalse(model.canConfirm)
        model.selectedID = 1
        XCTAssertTrue(model.canConfirm)
        model.confirming = true
        XCTAssertFalse(model.canConfirm)
    }

    func testRefreshKeepsSelectedWindowWhenOnlyItsTitleChanges() async {
        var options = [CaptureSourceOption(id: 10, title: "Old title", ownerProcessID: 42)]
        let model = SourceSelectionModel(mode: .window) { options }
        await model.refresh()
        model.selectedID = 10
        options = [CaptureSourceOption(id: 10, title: "New title", ownerProcessID: 42)]
        await model.refresh()
        XCTAssertEqual(model.selectedID, 10)
        XCTAssertEqual(model.selectedOption?.title, "New title")
    }

    func testDisappearingWindowDoesNotSelectAnotherWindow() async {
        var options = [CaptureSourceOption(id: 10, title: "A", ownerProcessID: 42)]
        let model = SourceSelectionModel(mode: .window) { options }
        await model.refresh()
        model.selectedID = 10
        options = [CaptureSourceOption(id: 11, title: "B", ownerProcessID: 42)]
        await model.refresh()
        XCTAssertNil(model.selectedID)
        XCTAssertFalse(model.canConfirm)
    }

    func testWindowIDReusedByAnotherProcessClearsSelection() async {
        var options = [CaptureSourceOption(id: 10, title: "A", ownerProcessID: 42)]
        let model = SourceSelectionModel(mode: .window) { options }
        await model.refresh()
        model.selectedID = 10
        options = [CaptureSourceOption(id: 10, title: "B", ownerProcessID: 99)]
        await model.refresh()
        XCTAssertNil(model.selectedID)
        XCTAssertFalse(model.canConfirm)
    }

    func testPermissionFailureProvidesAnActionableError() async {
        let model = SourceSelectionModel(mode: .display) { throw SourceSelectionError.permissionRequired }
        await model.refresh()
        XCTAssertFalse(model.loading)
        XCTAssertFalse(model.canConfirm)
        XCTAssertTrue(model.error?.text(language: .english).contains("macOS picker") == true)
        XCTAssertTrue(model.error?.text(language: .simplifiedChinese).contains("系统选源器") == true)
    }

    func testCancelledLoadingCannotRepopulateDismissedChooser() async {
        var pending: CheckedContinuation<[CaptureSourceOption], Error>?
        let started = expectation(description: "load started")
        let model = SourceSelectionModel(mode: .display) {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }
        let task = Task { await model.refresh() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.loading)
        model.cancel()
        guard let pending else { XCTFail("Load must start"); task.cancel(); return }
        pending.resume(returning: [CaptureSourceOption(id: 1, title: "Late result")])
        await task.value
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.options.isEmpty)
    }

    func testNewestRefreshWinsWhenRequestsFinishOutOfOrder() async {
        var pending: [CheckedContinuation<[CaptureSourceOption], Error>] = []
        let firstStarted = expectation(description: "first load started")
        let secondStarted = expectation(description: "second load started")
        let model = SourceSelectionModel(mode: .display) {
            try await withCheckedThrowingContinuation { continuation in
                pending.append(continuation)
                if pending.count == 1 { firstStarted.fulfill() }
                else { secondStarted.fulfill() }
            }
        }
        let first = Task { await model.refresh() }
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = Task { await model.refresh() }
        await fulfillment(of: [secondStarted], timeout: 2)
        guard pending.count == 2 else { XCTFail("Both requests must start"); return }
        pending[1].resume(returning: [CaptureSourceOption(id: 2, title: "New")])
        await second.value
        pending[0].resume(returning: [CaptureSourceOption(id: 1, title: "Old")])
        await first.value
        XCTAssertEqual(model.options.map(\.id), [2])
        XCTAssertFalse(model.loading)
    }
}
