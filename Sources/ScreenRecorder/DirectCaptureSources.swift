import AppKit
import ScreenCaptureKit
import RecorderCore

@MainActor
enum DirectCaptureSources {
    private static func content() async throws -> SCShareableContent {
        return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }

    private static func selectable(_ window: SCWindow) -> Bool {
        window.isOnScreen && window.windowLayer == 0 && window.frame.width >= 2 && window.frame.height >= 2 &&
            window.owningApplication != nil && window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
    }

    static func options(for mode: RecordingSource) async throws -> [CaptureSourceOption] {
        let content = try await content()
        if mode == .display {
            return content.displays.sorted { $0.displayID < $1.displayID }.enumerated().map { index, display in
                let screen = NSScreen.screens.first {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let scale = CGFloat(filter.pointPixelScale)
                let size = filter.contentRect.size
                let name = screen?.localizedName ?? L10n.text("Display", "屏幕")
                let detail = "\(Int(size.width * scale)) × \(Int(size.height * scale)) px" +
                    (display.displayID == CGMainDisplayID() ? L10n.text(" · Main display", " · 主屏幕") : "")
                return CaptureSourceOption(id: display.displayID, title: "\(index + 1) · \(name)", detail: detail)
            }
        }
        return content.windows.compactMap { window -> CaptureSourceOption? in
            guard selectable(window), let app = window.owningApplication else { return nil }
            let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return CaptureSourceOption(id: window.windowID,
                                       title: title.isEmpty ? L10n.text("Untitled window", "无标题窗口") : title,
                                       detail: app.applicationName, ownerProcessID: app.processID)
        }.sorted { lhs, rhs in
            let appOrder = lhs.detail.localizedCaseInsensitiveCompare(rhs.detail)
            if appOrder != .orderedSame { return appOrder == .orderedAscending }
            let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            return titleOrder == .orderedSame ? lhs.id < rhs.id : titleOrder == .orderedAscending
        }
    }

    /// Resolve against a fresh snapshot immediately before starting a preview.
    static func resolve(_ option: CaptureSourceOption, mode: RecordingSource) async throws -> SCContentFilter {
        let content = try await content()
        if mode == .display {
            guard let display = content.displays.first(where: { $0.displayID == option.id }) else {
                throw SourceSelectionError.unavailable
            }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        }
        guard let window = content.windows.first(where: {
            $0.windowID == option.id && $0.owningApplication?.processID == option.ownerProcessID && selectable($0)
        }) else { throw SourceSelectionError.unavailable }
        return SCContentFilter(desktopIndependentWindow: window)
    }
}
