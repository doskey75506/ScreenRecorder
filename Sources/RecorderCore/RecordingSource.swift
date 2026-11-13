import Foundation

public enum RecordingSource: String, CaseIterable, Identifiable, Sendable {
    case area, display, window

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .area: L10n.text("Area", "区域")
        case .display: L10n.text("Screen", "屏幕")
        case .window: L10n.text("Window", "窗口")
        }
    }
    public var systemImage: String {
        switch self {
        case .area: "viewfinder"
        case .display: "display"
        case .window: "macwindow"
        }
    }
}
