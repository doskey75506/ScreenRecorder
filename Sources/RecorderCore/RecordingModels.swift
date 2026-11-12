import Foundation
import CoreGraphics

public enum VideoCodec: String, CaseIterable, Identifiable, Sendable {
    case h264, hevc, vp9, av1
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .h264: "H.264（兼容性优先）"
        case .hevc: "HEVC / H.265"
        case .vp9: "VP9（网页视频）"
        case .av1: "AV1（编码较慢）"
        }
    }
    public var containers: [VideoContainer] {
        switch self {
        case .h264, .hevc: [.mp4, .mov, .mkv]
        case .vp9: [.webm, .mkv]
        case .av1: [.mp4, .webm, .mkv]
        }
    }
    public var encoder: String {
        switch self {
        case .h264: "libx264"
        case .hevc: "libx265"
        case .vp9: "libvpx-vp9"
        case .av1: "libsvtav1"
        }
    }
}

public enum VideoContainer: String, CaseIterable, Identifiable, Sendable {
    case mp4, mov, mkv, webm
    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
}

public enum CaptureResolution: String, CaseIterable, Identifiable, Sendable {
    case native, fullHD, compact
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .native: "原始分辨率"
        case .fullHD: "1080p（保持比例）"
        case .compact: "640 × 480（保持比例）"
        }
    }

    public func outputSize(for size: CGSize) -> CGSize {
        let bounds = self == .compact ? CGSize(width: 640, height: 480) : CGSize(width: 1920, height: 1080)
        let scale = self == .native ? 1 : min(1, min(bounds.width / max(2, size.width), bounds.height / max(2, size.height)))
        return CGSize(width: max(2, floor(size.width * scale / 2) * 2),
                      height: max(2, floor(size.height * scale / 2) * 2))
    }
}

public enum RecordingPhase: Equatable, Sendable {
    case idle, selecting, preparing, ready, starting, recording, stopping
    public var isBusy: Bool { [.selecting, .preparing, .starting, .recording, .stopping].contains(self) }
    public var canStart: Bool { self == .ready }
    public var canStop: Bool { self == .recording }
    public var title: String {
        switch self {
        case .idle: "未选择录制来源"
        case .selecting: "请选择显示器或窗口"
        case .preparing: "正在准备预览…"
        case .ready: "准备就绪"
        case .starting: "正在启动录制…"
        case .recording: "正在录制"
        case .stopping: "正在保存录制…"
        }
    }
}

/// Pixel margins in the displayed, orientation-correct video coordinate system.
public struct CropMargins: Equatable, Sendable {
    public var left: Double = 0
    public var top: Double = 0
    public var right: Double = 0
    public var bottom: Double = 0

    public init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }

    public func rect(in size: CGSize) throws -> CGRect {
        let values = [left, top, right, bottom, size.width, size.height]
        guard values.allSatisfy({ $0.isFinite }), [left, top, right, bottom].allSatisfy({ $0 >= 0 }),
              size.width - left - right >= 2, size.height - top - bottom >= 2 else {
            throw ValidationError.invalidCrop
        }
        // Even output dimensions work with 4:2:0 H.264 and HEVC encoders.
        return CGRect(x: floor(left), y: floor(top),
                      width: floor((size.width - left - right) / 2) * 2,
                      height: floor((size.height - top - bottom) / 2) * 2)
    }

    public static func from(rect: CGRect, in size: CGSize) -> CropMargins {
        let bounded = rect.standardized.intersection(CGRect(origin: .zero, size: size))
        guard !bounded.isNull else { return CropMargins() }
        return CropMargins(left: max(0, bounded.minX), top: max(0, bounded.minY),
                           right: max(0, size.width - bounded.maxX), bottom: max(0, size.height - bounded.maxY))
    }
}

public struct TrimRange: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public func validate(duration: Double) throws {
        guard start.isFinite, end.isFinite, duration.isFinite,
              start >= 0, end > start, end <= duration + 0.001 else { throw ValidationError.invalidTimeRange }
    }
}

public enum ValidationError: LocalizedError {
    case invalidCrop, invalidTimeRange, noVideo, unsupportedFormat, insufficientSpace, destinationUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidCrop: "裁剪范围无效，请保留至少 2 × 2 像素的画面。"
        case .invalidTimeRange: "时间范围无效，结束时间必须大于开始时间且不超过视频时长。"
        case .noVideo: "文件中没有可读取的视频轨道。"
        case .unsupportedFormat: "当前设备不支持所选编码与容器组合。"
        case .insufficientSpace: "剩余磁盘空间不足，请选择其他保存位置。"
        case .destinationUnavailable: "保存目录不可写，请重新选择。"
        }
    }
}

public enum RecordingFiles {
    public static func uniqueURL(directory: URL, stem: String, container: VideoContainer,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var candidate = directory.appendingPathComponent(stem).appendingPathExtension(container.rawValue)
        var suffix = 1
        while exists(candidate) {
            candidate = directory.appendingPathComponent("\(stem)-\(suffix)").appendingPathExtension(container.rawValue)
            suffix += 1
        }
        return candidate
    }

    public static func timestampStem(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Recording-" + formatter.string(from: date)
    }

    public static func checkDestination(_ directory: URL, minimumBytes: Int64 = 100 * 1024 * 1024) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: directory.path) else { throw ValidationError.destinationUnavailable }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        if let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value < minimumBytes {
            throw ValidationError.insufficientSpace
        }
    }
}

public func timeLabel(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00:00" }
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
}
