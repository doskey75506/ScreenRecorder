import Foundation
import RecorderCore
import ScreenCaptureKit

/// Diagnose the actual ScreenCaptureKit error rather than inferring permission
/// denial from an unrelated failure or a CoreGraphics preflight result.
enum CaptureFailure {
    static func isPermissionDenied(_ error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == SCStreamErrorDomain && failure.code == SCStreamError.Code.userDeclined.rawValue
    }

    static func message(for error: Error, bundle: Bundle = .main) -> LocalizedMessage {
        let failure = error as NSError
        let detail = LocalizedMessage(error: error)
        let code = "\(failure.domain) (\(failure.code))"
        guard isPermissionDenied(error) else {
            return LocalizedMessage("Could not capture content: \(detail.english)\n\(code)",
                                    "无法捕获画面：\(detail.chinese)\n\(code)")
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let identity = "\(bundle.bundleURL.path) · build \(version)"
        return LocalizedMessage(
            "macOS denied recording access to this copy. Quit ScreenRecorder and reopen the installed app. If its switch is already on, remove the old entry in Screen & System Audio Recording, add this app again, and restart it. Ad hoc signed updates may need a new grant.\n\(identity)\n\(code)",
            "macOS 拒绝了当前副本的录屏访问。请退出 ScreenRecorder 后重新打开已安装的应用。如开关已开启，请在“屏幕与系统音频录制”中移除旧条目，重新添加此应用并重启。临时签名的更新版本可能需要重新授权。\n\(identity)\n\(code)")
    }
}
