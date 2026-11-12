import AVFoundation
import XCTest
import RecorderCore
@testable import ScreenRecorder

@MainActor
final class VideoEditorTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        guard MediaFormats.tool("ffmpeg") != nil, MediaFormats.tool("ffprobe") != nil else {
            throw XCTSkip("Install FFmpeg and ffprobe to run the real transcoding tests.")
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenRecorderTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testCropAndTrimPreserveSourceAndOutputCorrectMedia() async throws {
        let source = try await makeFixture()
        let original = try Data(contentsOf: source)
        let editor = VideoEditor()
        await editor.load(source)
        XCTAssertTrue(editor.hasVideo, editor.message ?? "")
        XCTAssertEqual(editor.size, CGSize(width: 640, height: 480))
        editor.quality = .high
        editor.crop = CropMargins(left: 320, top: 0, right: 0, bottom: 240)
        editor.start = 0.5
        editor.end = 1.5
        let output = directory.appendingPathComponent("cropped.mp4")
        await editor.export(to: output)
        XCTAssertEqual(editor.exportedURL, output, editor.message ?? "")
        XCTAssertEqual(try Data(contentsOf: source), original)
        let probe = try await probe(output)
        XCTAssertEqual(probe.size, CGSize(width: 320, height: 240))
        XCTAssertEqual(probe.duration, 1, accuracy: 0.05)
        let raw = try await MediaProcess().run(tool: "ffmpeg", arguments: [
            "-v", "error", "-i", output.path, "-frames:v", "1", "-vf", "scale=1:1", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"
        ])
        XCTAssertEqual(raw.count, 3)
        XCTAssertGreaterThan(raw[1], 170, "Top-right crop must be green")
        XCTAssertLessThan(raw[0], 70)
        XCTAssertLessThan(raw[2], 70)
        editor.player.replaceCurrentItem(with: nil)
    }

    func testPortraitVideoCropUsesDisplayedCoordinates() async throws {
        let source = try await makeFixture(rotated: true)
        let editor = VideoEditor()
        await editor.load(source)
        XCTAssertEqual(editor.size, CGSize(width: 480, height: 640))
        editor.crop = CropMargins(left: 40, top: 80, right: 40, bottom: 80)
        let output = directory.appendingPathComponent("portrait.mov")
        editor.container = .mov
        await editor.export(to: output)
        XCTAssertEqual(editor.exportedURL, output, editor.message ?? "")
        let metadata = try await probe(output)
        XCTAssertEqual(metadata.size, CGSize(width: 400, height: 480))
        editor.player.replaceCurrentItem(with: nil)
    }

    func testOriginalCannotBeOverwrittenAndExistingDestinationGetsNewName() async throws {
        let source = try await makeFixture()
        let editor = VideoEditor()
        await editor.load(source)
        await editor.export(to: source)
        XCTAssertNil(editor.exportedURL)
        XCTAssertEqual(editor.message, L10n.text("Cannot overwrite the original video.", "不能覆盖原始视频。"))
        let existing = directory.appendingPathComponent("existing.mp4")
        try Data("keep".utf8).write(to: existing)
        await editor.export(to: existing)
        XCTAssertEqual(editor.exportedURL?.lastPathComponent, "existing-1.mp4", editor.message ?? "")
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
        editor.player.replaceCurrentItem(with: nil)
    }

    func testCancellationRemovesPartialOutput() async throws {
        let source = try await makeFixture()
        let editor = VideoEditor()
        await editor.load(source)
        let output = directory.appendingPathComponent("cancelled.mp4")
        let export = Task { await editor.export(to: output) }
        while !editor.exporting { await Task.yield() }
        editor.cancelExport()
        await export.value
        XCTAssertFalse(editor.exporting)
        XCTAssertNil(editor.exportedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.contains("partial") })
        editor.player.replaceCurrentItem(with: nil)
    }

    func testEveryAvailableCodecAndContainerCanExportAndReimport() async throws {
        let source = try await makeFixture(audio: true)
        let editor = VideoEditor()
        await editor.load(source)
        editor.resolution = .compact
        editor.quality = .compact
        for codec in MediaFormats.exportCodecs {
            for container in codec.containers {
                editor.codec = codec
                editor.container = container
                let output = directory.appendingPathComponent("\(codec.rawValue).\(container.rawValue)")
                await editor.export(to: output)
                XCTAssertEqual(editor.exportedURL, output, editor.message ?? "")
                guard editor.exportedURL != nil else { continue }
                let result = try await probe(output)
                XCTAssertEqual(result.size, CGSize(width: 640, height: 480))
                XCTAssertEqual(result.audioCount, 1, "Source audio tracks must be mixed")
                XCTAssertEqual(result.duration, 2, accuracy: 0.15)
                let reopened = VideoEditor()
                await reopened.load(output)
                XCTAssertTrue(reopened.hasVideo, reopened.message ?? "")
                reopened.player.replaceCurrentItem(with: nil)
            }
        }
        editor.player.replaceCurrentItem(with: nil)
    }

    func testSmallFileQualityActuallyReducesSizeAndEstimateUpdates() async throws {
        let source = directory.appendingPathComponent("detailed.mp4")
        _ = try await MediaProcess().run(tool: "ffmpeg", arguments: [
            "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30", "-t", "3", "-an",
            "-c:v", "libx264", "-crf", "16", source.path
        ])
        let editor = VideoEditor()
        await editor.load(source)
        let highEstimate = editor.estimatedBytes(for: .high)
        let compactEstimate = editor.estimatedBytes(for: .compact)
        XCTAssertGreaterThan(highEstimate, compactEstimate)
        editor.quality = .high
        let high = directory.appendingPathComponent("high.mp4")
        await editor.export(to: high)
        XCTAssertEqual(editor.exportedURL, high, editor.message ?? "")
        editor.quality = .compact
        editor.resolution = .compact
        let small = directory.appendingPathComponent("small.mp4")
        await editor.export(to: small)
        XCTAssertEqual(editor.exportedURL, small, editor.message ?? "")
        let result = try await probe(small)
        XCTAssertEqual(result.size, CGSize(width: 640, height: 360))
        let highSize = try high.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        let smallSize = try small.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        XCTAssertLessThan(smallSize, highSize)
        XCTAssertLessThan(Int64(smallSize), editor.sourceBytes)
        editor.player.replaceCurrentItem(with: nil)
    }

    func testRecordingCompletionReusesTheSameTranscoder() async throws {
        guard MediaFormats.exportCodecs.contains(.vp9) else { throw XCTSkip("VP9 encoder unavailable") }
        let source = try await makeFixture()
        let original = try Data(contentsOf: source)
        let destination = directory.appendingPathComponent("recorded.webm")
        let editor = VideoEditor()
        await editor.openRecording(CompletedRecording(source: source, destination: destination, codec: .vp9, container: .webm))
        XCTAssertEqual(editor.exportedURL, destination, editor.message ?? "")
        XCTAssertEqual(try Data(contentsOf: source), original)
        let output = try await probe(destination)
        XCTAssertEqual(output.size, CGSize(width: 640, height: 480))
        editor.player.replaceCurrentItem(with: nil)
    }

    func testSecondExportStillWorksAfterOriginalAndFirstExportAreDeleted() async throws {
        let source = try await makeFixture()
        let editor = VideoEditor()
        await editor.load(source)
        editor.start = 0.1
        editor.end = 1.6
        let first = directory.appendingPathComponent("first.mp4")
        await editor.export(to: first)
        XCTAssertEqual(editor.exportedURL, first, editor.message ?? "")
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: first)
        editor.start = 0.5
        editor.end = 1.5
        let second = directory.appendingPathComponent("second.mp4")
        await editor.export(to: second)
        XCTAssertEqual(editor.exportedURL, second, editor.message ?? "")
        XCTAssertEqual(editor.sourceURL, source, "Export must never switch the editing source to a previous output")
        let metadata = try await probe(second)
        XCTAssertEqual(metadata.duration, 1, accuracy: 0.05)
        editor.newProject()
    }

    func testSessionCopySurvivesInPlaceSourceChangesAndIsCleanedUp() async throws {
        let source = try await makeFixture()
        let original = try Data(contentsOf: source)
        let editor = VideoEditor()
        await editor.load(source)
        let snapshot = try XCTUnwrap(editor.sources.first?.snapshot.workingURL)
        try Data("replaced externally".utf8).write(to: source)
        XCTAssertEqual(try Data(contentsOf: snapshot), original)
        let output = directory.appendingPathComponent("stable.mp4")
        await editor.export(to: output)
        XCTAssertEqual(editor.exportedURL, output, editor.message ?? "")
        editor.newProject()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("replaced externally".utf8))
    }

    func testClipEditingReorderingAndDraftIsolation() async throws {
        let source = try await makeFixture()
        let editor = VideoEditor()
        await editor.load(source)
        editor.start = 0.1; editor.end = 0.6
        editor.addClip()
        let first = try XCTUnwrap(editor.clips.first?.id)
        editor.start = 1; editor.end = 1.5
        editor.addClip()
        let second = try XCTUnwrap(editor.clips.last?.id)
        await editor.editClip(first)
        XCTAssertEqual(editor.start, 0.1)
        editor.end = 0.8
        editor.crop = CropMargins(left: 20)
        editor.updateSelectedClip()
        XCTAssertEqual(editor.clips.first?.id, first)
        XCTAssertEqual(editor.clips.first?.crop.left, 20)
        XCTAssertEqual(editor.exportDuration, 1.2, accuracy: 0.001)
        editor.moveClip(second, offset: -1)
        XCTAssertEqual(editor.clips.first?.id, second)
        editor.start = 2; editor.end = 1
        XCTAssertFalse(editor.validDraft)
        XCTAssertTrue(editor.validEdit, "Uncommitted draft changes must not invalidate selected clips")
        editor.removeClip(second)
        XCTAssertEqual(editor.clips.count, 1)
        editor.clearClips()
        XCTAssertFalse(editor.validEdit)
        editor.newProject()
    }

    func testMissingImportKeepsExistingClipsAndDraftParameters() async throws {
        let source = try await makeFixture()
        let editor = VideoEditor()
        await editor.load(source)
        editor.start = 0.1; editor.end = 0.8
        editor.crop = CropMargins(left: 20)
        editor.addClip()
        let clips = editor.clips
        await editor.load(directory.appendingPathComponent("missing.mp4"))
        XCTAssertEqual(editor.sourceURL, source)
        XCTAssertEqual(editor.clips, clips)
        XCTAssertEqual(editor.start, 0.1)
        XCTAssertEqual(editor.end, 0.8)
        XCTAssertEqual(editor.crop.left, 20)
        XCTAssertTrue(editor.message?.contains(L10n.text("Cannot find or read", "找不到")) == true)
        editor.newProject()
    }

    func testMultipleVideosConcatenateOnlySelectedRangesInListOrder() async throws {
        let a = try await makeTimelineFixture()
        let b = directory.appendingPathComponent("portrait-silent.mp4")
        _ = try await MediaProcess().run(tool: "ffmpeg", arguments: ["-v", "error", "-f", "lavfi", "-i",
            "color=yellow:s=240x320:r=24:d=2", "-c:v", "libx264", b.path])
        let editor = VideoEditor()
        await editor.load(a)
        editor.start = 0.1; editor.end = 0.6
        editor.addClip() // red
        editor.start = 2.2; editor.end = 2.7
        editor.addClip() // blue
        let blue = try XCTUnwrap(editor.clips.last?.id)
        await editor.load(b)
        XCTAssertEqual(editor.sources.count, 2)
        editor.start = 0.4; editor.end = 0.9
        editor.addClip() // yellow
        let yellow = try XCTUnwrap(editor.clips.last?.id)
        editor.moveClip(blue, offset: -1)
        editor.moveClip(yellow, offset: -1) // blue, yellow, red
        XCTAssertEqual(editor.exportDuration, 1.5, accuracy: 0.001)
        // Keep all three snapshots usable when the original files disappear.
        try FileManager.default.removeItem(at: a)
        try FileManager.default.removeItem(at: b)
        let output = directory.appendingPathComponent("merged.mp4")
        await editor.export(to: output)
        XCTAssertEqual(editor.exportedURL, output, editor.message ?? "")
        guard editor.exportedURL != nil else { return }
        let metadata = try await probe(output)
        XCTAssertEqual(metadata.size, CGSize(width: 640, height: 360))
        XCTAssertEqual(metadata.duration, 1.5, accuracy: 0.1)
        XCTAssertEqual(metadata.audioCount, 1)
        let bluePixel = try await pixel(output, at: 0.2)
        let yellowPixel = try await pixel(output, at: 0.7)
        let redPixel = try await pixel(output, at: 1.2)
        XCTAssertGreaterThan(bluePixel[2], 170); XCTAssertLessThan(bluePixel[0], 70)
        XCTAssertGreaterThan(yellowPixel[0], 170); XCTAssertGreaterThan(yellowPixel[1], 170)
        XCTAssertGreaterThan(redPixel[0], 170); XCTAssertLessThan(redPixel[2], 70)
        let border = try await pixel(output, at: 0.7, x: 0, y: 0)
        XCTAssertLessThan(border.max() ?? 255, 25, "Portrait clip must be padded, not stretched")
        let audible = try await audioRMS(output, at: 0.1)
        let silent = try await audioRMS(output, at: 0.65)
        XCTAssertGreaterThan(audible, 0.02)
        XCTAssertLessThan(silent, 0.002)
        editor.newProject()
    }

    func testSilentConcatenationCancellationAndSecondExport() async throws {
        let source = try await makeTimelineFixture(audio: false)
        let editor = VideoEditor()
        await editor.load(source)
        editor.start = 2; editor.end = 2.5; editor.addClip()
        editor.start = 0; editor.end = 0.5; editor.addClip()
        let cancelled = directory.appendingPathComponent("cancelled-merge.mp4")
        let task = Task { await editor.export(to: cancelled) }
        while !editor.exporting { await Task.yield() }
        editor.cancelExport()
        await task.value
        XCTAssertNil(editor.exportedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        let output = directory.appendingPathComponent("silent-merge.mp4")
        await editor.export(to: output)
        XCTAssertEqual(editor.exportedURL, output, editor.message ?? "")
        guard editor.exportedURL != nil else { return }
        let metadata = try await probe(output)
        XCTAssertEqual(metadata.audioCount, 0)
        XCTAssertEqual(metadata.duration, 1, accuracy: 0.1)
        XCTAssertEqual(editor.clips.count, 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(files.contains { $0.contains("partial") })
        editor.newProject()
    }

    private func makeTimelineFixture(audio: Bool = true) async throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        let filter = "color=red:s=640x360:r=30:d=1[r];color=lime:s=640x360:r=30:d=1[g];" +
            "color=blue:s=640x360:r=30:d=1[b];[r][g][b]concat=n=3:v=1:a=0"
        var args = ["-v", "error", "-f", "lavfi", "-i", filter]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-c:a", "aac"] }
        args += ["-t", "3", "-c:v", "libx264", "-pix_fmt", "yuv420p", url.path]
        _ = try await MediaProcess().run(tool: "ffmpeg", arguments: args)
        return url
    }

    private func pixel(_ url: URL, at time: Double, x: Int = 320, y: Int = 180) async throws -> [UInt8] {
        let data = try await MediaProcess().run(tool: "ffmpeg", arguments: ["-v", "error", "-ss", String(time),
            "-i", url.path, "-frames:v", "1", "-vf", "crop=2:2:\(x):\(y),scale=1:1", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"])
        return Array(data)
    }

    private func audioRMS(_ url: URL, at time: Double) async throws -> Double {
        let data = try await MediaProcess().run(tool: "ffmpeg", arguments: ["-v", "error", "-ss", String(time),
            "-i", url.path, "-t", "0.15", "-vn", "-ac", "1", "-f", "f32le", "pipe:1"])
        return data.withUnsafeBytes { bytes in
            let count = data.count / 4
            let energy = (0..<count).reduce(0.0) { total, index in
                let sample = Double(bytes.loadUnaligned(fromByteOffset: index * 4, as: Float.self))
                return total + sample * sample
            }
            return sqrt(energy / Double(max(1, count)))
        }
    }

    private func probe(_ url: URL) async throws -> ProbedMedia {
        let data = try await MediaProcess().run(tool: "ffprobe", arguments: ["-v", "error", "-show_streams", "-show_format", "-of", "json", url.path])
        return try JSONDecoder().decode(ProbedMedia.self, from: data)
    }

    private func makeFixture(rotated: Bool = false, audio: Bool = false) async throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        let filter = "color=c=black:s=640x480:r=30," +
            "drawbox=x=0:y=0:w=320:h=240:color=red:t=fill," +
            "drawbox=x=320:y=0:w=320:h=240:color=lime:t=fill," +
            "drawbox=x=0:y=240:w=320:h=240:color=blue:t=fill," +
            "drawbox=x=320:y=240:w=320:h=240:color=white:t=fill"
        var args = ["-v", "error", "-f", "lavfi", "-i", filter]
        if audio {
            args += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                     "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000", "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:a", "aac"]
        }
        args += ["-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", url.path]
        _ = try await MediaProcess().run(tool: "ffmpeg", arguments: args)
        if rotated {
            let output = directory.appendingPathComponent("rotated.mp4")
            _ = try await MediaProcess().run(tool: "ffmpeg", arguments: ["-v", "error", "-display_rotation", "90", "-i", url.path,
                "-c", "copy", output.path])
            return output
        }
        return url
    }
}
