import Foundation
import CoreGraphics

public struct EditClip: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sourceID: UUID
    public let name: String
    public var trim: TrimRange
    public var crop: CropMargins
    public init(id: UUID = UUID(), sourceID: UUID, name: String, trim: TrimRange, crop: CropMargins) {
        self.id = id; self.sourceID = sourceID; self.name = name; self.trim = trim; self.crop = crop
    }
    public var duration: Double { trim.end - trim.start }
}

public struct ConcatSegment: Sendable {
    public let input: URL
    public let trim: TrimRange
    public let crop: CGRect
    public let audioTrackCount: Int
    public init(input: URL, trim: TrimRange, crop: CGRect, audioTrackCount: Int) {
        self.input = input; self.trim = trim; self.crop = crop; self.audioTrackCount = audioTrackCount
    }
}

extension TranscodeSettings {
    /// Normalize each selected segment before concatenating; unmatched aspect ratios get black bars.
    public func concatenationArguments(segments: [ConcatSegment], output: URL) -> [String] {
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-progress", "pipe:1",
                    "-filter_complex_threads", "1"]
        var filters: [String] = []
        let hasAudio = segments.contains { $0.audioTrackCount > 0 }
        var streams = ""
        let width = Int(outputSize.width), height = Int(outputSize.height)
        for (index, segment) in segments.enumerated() {
            let duration = segment.trim.end - segment.trim.start
            args += ["-protocol_whitelist", "file,pipe,crypto,data", "-ss", String(segment.trim.start),
                     "-t", String(duration), "-threads", "2", "-i", segment.input.path]
            let rect = segment.crop
            filters.append("[\(index):v:0]setpts=PTS-STARTPTS,crop=\(Int(rect.width)):\(Int(rect.height)):\(Int(rect.minX)):\(Int(rect.minY)):exact=1," +
                "scale=\(width):\(height):force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos," +
                "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(frameRate)," +
                "tpad=stop_mode=clone:stop_duration=\(duration),trim=duration=\(duration),setpts=PTS-STARTPTS[v\(index)]")
            streams += "[v\(index)]"
            if hasAudio {
                let prefix: String
                if segment.audioTrackCount > 1 {
                    prefix = (0..<segment.audioTrackCount).map { "[\(index):a:\($0)]" }.joined() +
                        "amix=inputs=\(segment.audioTrackCount):duration=longest:normalize=1,"
                } else if segment.audioTrackCount == 1 {
                    prefix = "[\(index):a:0]"
                } else {
                    prefix = "anullsrc=r=48000:cl=stereo,"
                }
                filters.append(prefix + "aresample=48000:async=1:first_pts=0,aformat=sample_fmts=fltp:channel_layouts=stereo," +
                    "asetpts=PTS-STARTPTS,apad,atrim=duration=\(duration),asetpts=PTS-STARTPTS[a\(index)]")
                streams += "[a\(index)]"
            }
        }
        filters.append(streams + "concat=n=\(segments.count):v=1:a=\(hasAudio ? 1 : 0)[v]" + (hasAudio ? "[a]" : ""))
        args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[v]"]
        args += hasAudio ? ["-map", "[a]"] : ["-an"]
        return args + encodingArguments(hasAudio: hasAudio) + [output.path]
    }
}
