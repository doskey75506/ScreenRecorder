import AppKit
import AVFoundation
import Combine
import RecorderCore
import UniformTypeIdentifiers

struct EditorSource: Identifiable {
    let id = UUID()
    let snapshot: EditingSource
    let media: ProbedMedia
    var name: String { snapshot.originalURL.lastPathComponent }
}

/// One editing/transcoding workflow for completed recordings and videos opened from disk.
@MainActor
final class VideoEditor: ObservableObject {
    @Published private(set) var sourceURL: URL?
    @Published private(set) var size = CGSize.zero
    @Published private(set) var duration = 0.0
    @Published private(set) var sourceBytes: Int64 = 0
    @Published private(set) var loading = false
    @Published private(set) var exporting = false
    @Published private(set) var progress: Float = 0
    @Published private(set) var exportedURL: URL?
    @Published private(set) var availableFormats: [VideoCodec: [VideoContainer]] = [:]
    @Published private(set) var nativePlayback = true
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var sources: [EditorSource] = []
    @Published private(set) var currentSourceID: UUID?
    @Published private(set) var clips: [EditClip] = []
    @Published private(set) var editedClipID: UUID?
    @Published var crop = CropMargins()
    @Published var start = 0.0
    @Published var end = 0.0
    @Published var codec: VideoCodec = .h264
    @Published var container: VideoContainer = .mp4
    @Published var quality: ExportQuality = .balanced
    @Published var resolution: CaptureResolution = .native
    @Published var message: String?
    let player = AVPlayer()

    private var media: ProbedMedia?
    private var runner: MediaProcess?
    private var cancelled = false
    private var thumbnailRunner: MediaProcess?
    private var thumbnailTask: Task<Void, Never>?
    private var exportID = UUID()

    var hasVideo: Bool { sourceURL != nil && !loading }
    var validDraft: Bool {
        guard hasVideo else { return false }
        return (try? crop.rect(in: size)) != nil && (try? TrimRange(start: start, end: end).validate(duration: duration)) != nil
    }
    var validEdit: Bool {
        guard !loading else { return false }
        if clips.isEmpty { return validDraft }
        return clips.allSatisfy { clip in
            guard let source = sources.first(where: { $0.id == clip.sourceID }) else { return false }
            return (try? clip.crop.rect(in: source.media.size)) != nil &&
                (try? clip.trim.validate(duration: source.media.duration)) != nil
        }
    }
    var exportDuration: Double { clips.isEmpty ? max(0, end - start) : clips.reduce(0) { $0 + $1.duration } }
    private var currentSource: EditorSource? { sources.first { $0.id == currentSourceID } }
    private var firstExportSource: EditorSource? {
        clips.first.flatMap { clip in sources.first { $0.id == clip.sourceID } } ?? currentSource
    }
    var outputSize: CGSize {
        if let clip = clips.first, let source = firstExportSource {
            return resolution.outputSize(for: (try? clip.crop.rect(in: source.media.size).size) ?? source.media.size)
        }
        return resolution.outputSize(for: (try? crop.rect(in: size).size) ?? size)
    }
    private func sourceBitRate(_ media: ProbedMedia) -> Double {
        if let value = Double(media.video?.bit_rate ?? ""), value > 0 { return value }
        return media.duration > 0 ? Double(media.fileBytes) * 8 / media.duration * (media.audioCount == 0 ? 1 : 0.9) : 0
    }
    func bitRate(for quality: ExportQuality) -> Int {
        let rate: (ProbedMedia) -> Int = { media in
            quality.videoBitRate(size: self.outputSize, frameRate: self.firstExportSource?.media.frameRate ?? 30, codec: self.codec,
                                 sourceBitRate: self.sourceBitRate(media), sourceSize: media.size)
        }
        if !clips.isEmpty, exportDuration > 0 {
            let budget = clips.reduce(0.0) { total, clip in
                guard let source = sources.first(where: { $0.id == clip.sourceID }) else { return total }
                return total + Double(rate(source.media)) * clip.duration
            }
            return max(32_000, Int(budget / exportDuration))
        }
        return media.map(rate) ?? 32_000
    }
    func estimatedBytes(for quality: ExportQuality) -> Int64 {
        guard validEdit else { return 0 }
        let hasAudio = clips.isEmpty ? (media?.audioCount ?? 0) > 0 : clips.contains { clip in
            (sources.first { $0.id == clip.sourceID }?.media.audioCount ?? 0) > 0
        }
        return quality.estimatedBytes(duration: exportDuration, videoBitRate: bitRate(for: quality), hasAudio: hasAudio)
    }
    func sizeLabel(for quality: ExportQuality) -> String {
        ByteCountFormatter.string(fromByteCount: estimatedBytes(for: quality), countStyle: .file)
    }

    func importVideo() async {
        guard !exporting, !loading else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .data]
        panel.allowsMultipleSelection = true
        panel.message = "导入一个或多个视频，再分别选取时间段加入拼接列表。已有片段会保留。"
        if panel.runModal() == .OK {
            for url in panel.urls { await load(url) }
        }
    }

    func openRecording(_ recording: CompletedRecording) async {
        await load(recording.source)
        guard sourceURL == recording.source else { return }
        clearClips()
        guard recording.needsConversion, sourceURL == recording.source else { return }
        codec = recording.codec
        container = recording.container
        await export(to: recording.destination)
        if exportedURL == nil {
            message = (message ?? "转换未完成。") + "\n原始录屏已保留：\(recording.source.path)"
        }
    }

    func load(_ url: URL) async {
        guard !loading, !exporting else { return }
        loading = true
        defer { loading = false }
        player.pause()
        message = nil
        thumbnailTask?.cancel()
        thumbnailRunner?.cancel()
        do {
            if let existing = sources.first(where: { $0.snapshot.originalURL.standardizedFileURL == url.standardizedFileURL }) {
                await activate(existing)
                return
            }
            let snapshot = try await Task.detached(priority: .userInitiated) { try EditingSource(url: url) }.value
            let data = try await MediaProcess().run(tool: "ffprobe", arguments: [
                "-v", "error", "-protocol_whitelist", "file,pipe,crypto,data", "-show_streams", "-show_format", "-of", "json", snapshot.workingURL.path
            ])
            let media = try JSONDecoder().decode(ProbedMedia.self, from: data)
            guard media.size.width >= 2, media.size.height >= 2,
                  media.duration.isFinite, media.duration > 0 else { throw ValidationError.noVideo }
            let source = EditorSource(snapshot: snapshot, media: media)
            let first = sources.isEmpty
            sources.append(source)
            availableFormats = Dictionary(uniqueKeysWithValues: MediaFormats.exportCodecs.map { ($0, $0.containers) })
            if first {
                quality = .balanced
                resolution = .native
                exportedURL = nil
                codec = MediaFormats.exportCodecs.first ?? .h264
                container = codec.containers.first ?? .mp4
            }
            await activate(source)
        } catch {
            message = "无法打开视频：\(error.localizedDescription)"
        }
    }

    private func activate(_ source: EditorSource, clip: EditClip? = nil) async {
        player.pause()
        thumbnailTask?.cancel()
        thumbnailRunner?.cancel()
        currentSourceID = source.id
        sourceURL = source.snapshot.originalURL
        media = source.media
        size = source.media.size
        duration = source.media.duration
        sourceBytes = source.media.fileBytes
        crop = clip?.crop ?? CropMargins()
        start = clip?.trim.start ?? 0
        end = clip?.trim.end ?? duration
        editedClipID = clip?.id
        thumbnail = nil
        let asset = AVURLAsset(url: source.snapshot.workingURL)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let decodable = (try? await tracks.first?.load(.isDecodable)) ?? false
        nativePlayback = playable && decodable
        player.replaceCurrentItem(with: nativePlayback ? AVPlayerItem(asset: asset) : nil)
        if !nativePlayback { await refreshThumbnail(at: start) }
    }

    func selectSource(_ id: UUID) async {
        guard !loading, !exporting, let source = sources.first(where: { $0.id == id }) else { return }
        loading = true
        defer { loading = false }
        await activate(source)
    }

    func addClip() {
        guard !exporting, validDraft, let source = currentSource else { return }
        let clip = EditClip(sourceID: source.id, name: source.name, trim: TrimRange(start: start, end: end), crop: crop)
        clips.append(clip)
        editedClipID = clip.id
        message = "已加入片段 \(clips.count)。导出只包含列表中的片段；调整后请点击“更新所选片段”。"
    }

    func updateSelectedClip() {
        guard !exporting, validDraft, let id = editedClipID, let index = clips.firstIndex(where: { $0.id == id }),
              let source = currentSource else { return }
        clips[index] = EditClip(id: id, sourceID: source.id, name: source.name, trim: TrimRange(start: start, end: end), crop: crop)
        message = "所选片段已更新。"
    }

    func editClip(_ id: UUID) async {
        guard !loading, !exporting, let clip = clips.first(where: { $0.id == id }),
              let source = sources.first(where: { $0.id == clip.sourceID }) else { return }
        loading = true
        defer { loading = false }
        await activate(source, clip: clip)
    }

    func moveClip(_ id: UUID, offset: Int) {
        guard !exporting, !loading, let index = clips.firstIndex(where: { $0.id == id }),
              clips.indices.contains(index + offset) else { return }
        clips.swapAt(index, index + offset)
    }

    func removeClip(_ id: UUID) {
        guard !exporting, !loading else { return }
        clips.removeAll { $0.id == id }
        if editedClipID == id { editedClipID = nil }
    }

    func clearClips() {
        guard !exporting, !loading else { return }
        clips = []
        editedClipID = nil
    }

    func newProject() {
        guard !exporting, !loading else { return }
        thumbnailTask?.cancel()
        thumbnailRunner?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        clips = []
        for source in sources { source.snapshot.discard() }
        sources = []
        currentSourceID = nil
        editedClipID = nil
        sourceURL = nil
        media = nil
        thumbnail = nil
        size = .zero
        duration = 0
        sourceBytes = 0
        start = 0
        end = 0
        crop = CropMargins()
        nativePlayback = true
        exportedURL = nil
        message = nil
    }

    func closeSession() {
        thumbnailTask?.cancel()
        thumbnailRunner?.cancel()
        runner?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        for source in sources { source.snapshot.discard() }
    }

    func seek(_ seconds: Double) {
        guard hasVideo, seconds.isFinite, !exporting else { return }
        let time = max(0, min(seconds, max(0, duration - 0.001)))
        if nativePlayback {
            player.pause()
            player.currentItem?.forwardPlaybackEndTime = .invalid
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            thumbnailTask?.cancel()
            thumbnailRunner?.cancel()
            thumbnailTask = Task { await refreshThumbnail(at: time) }
        }
    }

    private func refreshThumbnail(at time: Double) async {
        guard let source = currentSource else { return }
        let process = MediaProcess()
        thumbnailRunner = process
        if let data = try? await process.run(tool: "ffmpeg", arguments: [
            "-v", "error", "-nostdin", "-protocol_whitelist", "file,pipe,crypto,data", "-ss", String(time),
            "-i", source.snapshot.workingURL.path, "-frames:v", "1", "-vf", "scale=960:-2", "-c:v", "mjpeg", "-f", "image2pipe", "pipe:1"
        ]), !Task.isCancelled, self.currentSourceID == source.id {
            thumbnail = NSImage(data: data)
        }
    }

    func previewSelection() {
        guard validDraft, nativePlayback else { return }
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor in self?.player.play() }
        }
    }

    func savePanel() -> URL? {
        guard validEdit, let sourceURL else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: container.rawValue) ?? .data]
        panel.canCreateDirectories = true
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent +
            (clips.isEmpty ? "-edited." : "-merged.") + container.rawValue
        panel.prompt = "导出新视频"
        guard panel.runModal() == .OK, let target = panel.url else { return nil }
        guard !isSourceDestination(target) else {
            message = "请选择新的文件名，原始视频不会被覆盖。"
            return nil
        }
        return target
    }

    private func isSourceDestination(_ target: URL) -> Bool {
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL
        return sources.contains { source in
            [source.snapshot.originalURL, source.snapshot.workingURL].contains {
                $0.resolvingSymlinksInPath().standardizedFileURL == resolved
            }
        }
    }

    func export(to requestedURL: URL) async {
        guard !exporting, validEdit, let currentSource else { return }
        guard !isSourceDestination(requestedURL) else {
            message = "不能覆盖原始视频。"
            return
        }
        exporting = true
        cancelled = false
        progress = 0
        exportedURL = nil
        message = nil
        let jobID = UUID()
        exportID = jobID
        player.pause()
        thumbnailTask?.cancel()
        thumbnailRunner?.cancel()
        let directory = requestedURL.deletingLastPathComponent()
        let selectedContainer = container
        let selectedClips = clips
        let selectedSources = sources
        let totalDuration = exportDuration
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).partial.\(container.rawValue)")
        defer {
            runner = nil
            exporting = false
            try? FileManager.default.removeItem(at: staging)
        }
        do {
            guard MediaFormats.exportCodecs.contains(codec), codec.containers.contains(container) else { throw ValidationError.unsupportedFormat }
            try RecordingFiles.checkDestination(directory)
            var segments: [ConcatSegment] = []
            if !selectedClips.isEmpty {
                for clip in selectedClips {
                    guard let source = selectedSources.first(where: { $0.id == clip.sourceID }),
                          FileManager.default.isReadableFile(atPath: source.snapshot.workingURL.path) else {
                        throw EditingSourceError.unavailable(clip.name)
                    }
                    try clip.trim.validate(duration: source.media.duration)
                    segments.append(ConcatSegment(input: source.snapshot.workingURL, trim: clip.trim,
                        crop: try clip.crop.rect(in: source.media.size), audioTrackCount: source.media.audioCount))
                }
            }
            guard FileManager.default.isReadableFile(atPath: currentSource.snapshot.workingURL.path) || !segments.isEmpty else {
                throw EditingSourceError.unavailable(currentSource.name)
            }
            let rect = try segments.first?.crop ?? crop.rect(in: size)
            let trim = segments.isEmpty ? TrimRange(start: start, end: end) : TrimRange(start: 0, end: totalDuration)
            if segments.isEmpty { try trim.validate(duration: duration) }
            let settings = TranscodeSettings(crop: rect, outputSize: outputSize, trim: trim, codec: codec,
                container: container, videoBitRate: bitRate(for: quality), audioBitRate: quality.audioBitRate,
                audioTrackCount: currentSource.media.audioCount, frameRate: firstExportSource?.media.frameRate ?? 30)
            let process = MediaProcess()
            runner = process
            guard !cancelled else { message = "已取消导出。"; return }
            let arguments = segments.isEmpty
                ? settings.arguments(input: currentSource.snapshot.workingURL, output: staging)
                : settings.concatenationArguments(segments: segments, output: staging)
            _ = try await process.run(tool: "ffmpeg", arguments: arguments) { [weak self] seconds in
                Task { @MainActor in
                    guard let self, self.exporting, self.exportID == jobID else { return }
                    self.progress = max(self.progress, Float(min(0.99, max(0, seconds / totalDuration))))
                }
            }
            guard !cancelled else { message = "已取消导出。"; return }
            let target = RecordingFiles.uniqueURL(directory: directory,
                stem: requestedURL.deletingPathExtension().lastPathComponent, container: selectedContainer)
            try FileManager.default.moveItem(at: staging, to: target)
            progress = 1
            exportedURL = target
            let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            message = "已导出：\(target.lastPathComponent)（\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))）"
        } catch {
            message = cancelled ? "已取消导出。" : "导出失败：\(error.localizedDescription)"
        }
    }

    func cancelExport() {
        cancelled = true
        runner?.cancel()
    }
}
