import XCTest
@testable import RecorderCore

final class LocalizationTests: XCTestCase {
    func testFirstLaunchAndUnsupportedPreferencesUseEnglish() {
        XCTAssertEqual(AppLanguage.resolve(nil), .english)
        XCTAssertEqual(AppLanguage.resolve(""), .english)
        XCTAssertEqual(AppLanguage.resolve("fr"), .english)
    }

    func testSavedLanguageResolvesWithoutFollowingSystemLanguage() {
        XCTAssertEqual(AppLanguage.resolve("en"), .english)
        XCTAssertEqual(AppLanguage.resolve("zh-Hans"), .simplifiedChinese)
    }

    func testExistingStatusMessageCanSwitchLanguageWithoutLosingFileName() {
        let fileName = "Demo-演示.mp4"
        let status = LocalizedMessage("Export cancelled.", "已取消导出。") +
            LocalizedMessage("\nOriginal kept: \(fileName)", "\n原文件已保留：\(fileName)")
        XCTAssertEqual(status.text(language: .english), "Export cancelled.\nOriginal kept: Demo-演示.mp4")
        XCTAssertEqual(status.text(language: .simplifiedChinese), "已取消导出。\n原文件已保留：Demo-演示.mp4")
        XCTAssertEqual(status.text(language: .english), "Export cancelled.\nOriginal kept: Demo-演示.mp4")
    }
}
