import Foundation
import ScreenCaptureKit
import AVFoundation
import RecorderCore

enum MediaFormats {
    static func tool(_ name: String) -> URL? {
        let candidates: [String?] = [Bundle.main.resourceURL?.appendingPathComponent("Tools/" + name).path(percentEncoded: false),
                                    "/opt/homebrew/bin/" + name, "/usr/local/bin/" + name, "/usr/bin/" + name]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static let exportCodecs: [VideoCodec] = {
        guard let executable = tool("ffmpeg") else { return [] }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["-hide_banner", "-encoders"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let names = Set(text.split(separator: "\n").compactMap { line -> String? in
                let fields = line.split(whereSeparator: \.isWhitespace)
                return fields.count > 1 ? String(fields[1]) : nil
            })
            return VideoCodec.allCases.filter { names.contains($0.encoder) }
        } catch { return [] }
    }()

    static var recordingCodecs: [VideoCodec] { exportCodecs.isEmpty ? [.h264] : exportCodecs }
    static func recordingContainers(for codec: VideoCodec) -> [VideoContainer] {
        exportCodecs.isEmpty ? [.mp4] : codec.containers
    }

    static func canRecordDirectly(codec: VideoCodec, container: VideoContainer) -> Bool {
        guard [.h264, .hevc].contains(codec), [.mp4, .mov].contains(container) else { return false }
        let configuration = SCRecordingOutputConfiguration()
        return configuration.availableVideoCodecTypes.contains(codec == .h264 ? .h264 : .hevc)
            && configuration.availableOutputFileTypes.contains(container == .mp4 ? .mp4 : .mov)
    }
}
