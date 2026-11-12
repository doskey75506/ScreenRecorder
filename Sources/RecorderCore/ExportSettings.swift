import Foundation
import CoreGraphics

public enum ExportQuality: String, CaseIterable, Identifiable, Sendable {
    case high, balanced, compact
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .high: "高画质"
        case .balanced: "均衡（推荐）"
        case .compact: "小文件"
        }
    }

    /// The same source-aware bitrate budget drives the size estimate and the actual encoder.
    public func videoBitRate(size: CGSize, frameRate: Double, codec: VideoCodec,
                             sourceBitRate: Double = 0, sourceSize: CGSize = .zero) -> Int {
        let bpp: Double = self == .high ? 0.16 : (self == .balanced ? 0.085 : 0.035)
        let efficiency: Double = codec == .h264 ? 1 : (codec == .hevc ? 0.7 : 0.65)
        let pixels = max(4, size.width * size.height)
        var rate = pixels * max(1, min(60, frameRate)) * bpp * efficiency
        if sourceBitRate.isFinite, sourceBitRate > 0, sourceSize.width > 0, sourceSize.height > 0 {
            let areaRatio = min(1, pixels / (sourceSize.width * sourceSize.height))
            let sourceFactor = self == .high ? 1 : (self == .balanced ? 0.8 : 0.4)
            rate = min(rate, sourceBitRate * areaRatio * sourceFactor)
        }
        return Int(max(32_000, min(100_000_000, rate)))
    }

    public var audioBitRate: Int { self == .high ? 192_000 : (self == .balanced ? 128_000 : 64_000) }

    public func estimatedBytes(duration: Double, videoBitRate: Int, hasAudio: Bool) -> Int64 {
        guard duration.isFinite, duration > 0 else { return 0 }
        let bits = Double(videoBitRate + (hasAudio ? audioBitRate : 0)) * duration
        return Int64(min(Double(Int64.max / 2), max(0, bits / 8 * 1.03)))
    }
}

public struct TranscodeSettings: Sendable {
    public let crop: CGRect
    public let outputSize: CGSize
    public let trim: TrimRange
    public let codec: VideoCodec
    public let container: VideoContainer
    public let videoBitRate: Int
    public let audioBitRate: Int
    public let audioTrackCount: Int
    public let frameRate: Double

    public init(crop: CGRect, outputSize: CGSize, trim: TrimRange, codec: VideoCodec, container: VideoContainer,
                videoBitRate: Int, audioBitRate: Int, audioTrackCount: Int, frameRate: Double) {
        self.crop = crop; self.outputSize = outputSize; self.trim = trim
        self.codec = codec; self.container = container; self.videoBitRate = videoBitRate
        self.audioBitRate = audioBitRate; self.audioTrackCount = audioTrackCount; self.frameRate = frameRate
    }

    public func arguments(input: URL, output: URL) -> [String] {
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-progress", "pipe:1",
                    "-protocol_whitelist", "file,pipe,crypto,data", "-ss", String(trim.start), "-i", input.path,
                    "-t", String(trim.end - trim.start), "-map", "0:v:0"]
        if audioTrackCount > 1 {
            let inputs = (0..<audioTrackCount).map { "[0:a:\($0)]" }.joined()
            args += ["-filter_complex", inputs + "amix=inputs=\(audioTrackCount):duration=longest:normalize=1[a]", "-map", "[a]"]
        } else if audioTrackCount == 1 {
            args += ["-map", "0:a:0"]
        } else {
            args += ["-an"]
        }
        let filter = "crop=\(Int(crop.width)):\(Int(crop.height)):\(Int(crop.minX)):\(Int(crop.minY)):exact=1," +
            "scale=\(Int(outputSize.width)):\(Int(outputSize.height)):flags=lanczos,setsar=1"
        return args + ["-vf", filter] + encodingArguments(hasAudio: audioTrackCount > 0) + [output.path]
    }

    public func encodingArguments(hasAudio: Bool) -> [String] {
        var args = ["-c:v", codec.encoder, "-b:v", String(videoBitRate),
                 "-pix_fmt", "yuv420p", "-threads", "4", "-r", String(max(1, min(60, frameRate))),
                 "-map_metadata", "-1", "-metadata:s:v:0", "rotate=0"]
        if codec != .av1 { args += ["-maxrate", String(videoBitRate * 2), "-bufsize", String(videoBitRate * 4)] }
        switch codec {
        case .h264: args += ["-preset", "medium"]
        case .hevc: args += ["-preset", "fast", "-x265-params", "pools=2:frame-threads=2:log-level=error"]
        case .vp9: args += ["-deadline", "good", "-cpu-used", "4", "-row-mt", "1"]
        case .av1: args += ["-preset", "8", "-svtav1-params", "lp=4"]
        }
        if codec == .hevc && [.mp4, .mov].contains(container) { args += ["-tag:v", "hvc1"] }
        if hasAudio {
            args += ["-c:a", container == .webm ? "libopus" : "aac", "-b:a", String(audioBitRate), "-ac", "2"]
        }
        if [.mp4, .mov].contains(container) { args += ["-movflags", "+faststart"] }
        return args
    }
}

public struct CompletedRecording: Equatable, Sendable {
    public let source: URL
    public let destination: URL
    public let codec: VideoCodec
    public let container: VideoContainer
    public var needsConversion: Bool { source != destination }
    public init(source: URL, destination: URL, codec: VideoCodec, container: VideoContainer) {
        self.source = source; self.destination = destination; self.codec = codec; self.container = container
    }
}
