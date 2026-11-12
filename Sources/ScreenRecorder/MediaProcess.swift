import Foundation
import RecorderCore
import Darwin

enum MediaToolError: BilingualLocalizedError {
    case missing(String), failed(String)
    var localizedMessage: LocalizedMessage {
        switch self {
        case .missing(let name): LocalizedMessage("\(name) was not found. Install FFmpeg (including ffprobe), then restart the app.", "未找到 \(name)。请安装 FFmpeg（包含 ffprobe），然后重新启动程序。")
        case .failed(let text): text.isEmpty ? LocalizedMessage("Video processing failed.", "视频处理失败。") : LocalizedMessage(text, text)
        }
    }
}

private final class ProcessData: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()
    func append(_ data: Data, isError: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isError {
            error.append(data)
            if error.count > 32768 { error = error.suffix(32768) }
        } else if output.count < 16 * 1024 * 1024 {
            output.append(data)
        }
    }
    func result() -> (Data, String) {
        lock.lock()
        defer { lock.unlock() }
        return (output, String(decoding: error, as: UTF8.self))
    }
}

/// Runs local media tools without a shell. Both pipes are drained concurrently off the UI thread.
@MainActor
final class MediaProcess {
    private var process: Process?

    func run(tool: String, arguments: [String], onTime: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        guard let executable = MediaFormats.tool(tool) else { throw MediaToolError.missing(tool) }
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        try process.run()
        self.process = process
        defer { self.process = nil }
        let result: (Data, String, Int32) = await withCheckedContinuation { continuation in
            let buffers = ProcessData()
            let readers = DispatchGroup()
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var pending = ""
                while let chunk = try? output.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                    buffers.append(chunk, isError: false)
                    if let onTime {
                        pending += String(decoding: chunk, as: UTF8.self)
                        while let newline = pending.firstIndex(of: "\n") {
                            let line = String(pending[..<newline])
                            pending.removeSubrange(...newline)
                            if line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst(12)) {
                                onTime(micros / 1_000_000)
                            }
                        }
                    }
                }
                readers.leave()
            }
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                while let chunk = try? error.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                    buffers.append(chunk, isError: true)
                }
                readers.leave()
            }
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                readers.wait()
                let (data, diagnostics) = buffers.result()
                continuation.resume(returning: (data, diagnostics, process.terminationStatus))
            }
        }
        guard result.2 == 0 else { throw MediaToolError.failed(result.1) }
        return result.0
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

struct ProbedMedia: Decodable {
    struct Stream: Decodable {
        struct SideData: Decodable { let rotation: Double? }
        let codec_type: String?
        let width: Int?
        let height: Int?
        let duration: String?
        let bit_rate: String?
        let avg_frame_rate: String?
        let sample_aspect_ratio: String?
        let side_data_list: [SideData]?
        let tags: [String: String]?
    }
    struct Format: Decodable { let duration: String?; let size: String? }
    let streams: [Stream]
    let format: Format

    var video: Stream? { streams.first { $0.codec_type == "video" && ($0.width ?? 0) > 0 } }
    var audioCount: Int { streams.filter { $0.codec_type == "audio" }.count }
    var duration: Double { Double(format.duration ?? video?.duration ?? "0") ?? 0 }
    var fileBytes: Int64 { Int64(format.size ?? "0") ?? 0 }
    var frameRate: Double {
        let parts = (video?.avg_frame_rate ?? "30/1").split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0, parts[0] > 0 else { return 30 }
        return min(60, parts[0] / parts[1])
    }
    var size: CGSize {
        guard let video else { return .zero }
        let rotation = video.side_data_list?.compactMap(\.rotation).first ?? Double(video.tags?["rotate"] ?? "0") ?? 0
        let natural = CGSize(width: video.width ?? 0, height: video.height ?? 0)
        return abs(Int(rotation.rounded())) % 180 == 90 ? CGSize(width: natural.height, height: natural.width) : natural
    }
}
