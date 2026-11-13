import XCTest
import ScreenCaptureKit
@testable import ScreenRecorder

final class CaptureFailureTests: XCTestCase {
    func testOnlyScreenCaptureKitDenialSuggestsPermissionRepair() {
        let denial = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        XCTAssertTrue(CaptureFailure.isPermissionDenied(denial))
        let message = CaptureFailure.message(for: denial)
        XCTAssertTrue(message.english.contains("remove the old entry"))
        XCTAssertTrue(message.chinese.contains("移除旧条目"))
        XCTAssertTrue(message.english.contains(Bundle.main.bundleURL.path))
    }

    func testCaptureConfigurationFailureDoesNotBlamePermission() {
        let error = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.invalidParameter.rawValue)
        XCTAssertFalse(CaptureFailure.isPermissionDenied(error))
        let message = CaptureFailure.message(for: error)
        XCTAssertFalse(message.english.contains("Screen & System Audio Recording"))
        XCTAssertTrue(message.english.contains("-3812"))
    }

    func testUnrelatedErrorWithSameCodeIsNotPermissionDenial() {
        let error = NSError(domain: "Other", code: SCStreamError.Code.userDeclined.rawValue)
        XCTAssertFalse(CaptureFailure.isPermissionDenied(error))
    }
}
