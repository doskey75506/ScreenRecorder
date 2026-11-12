import XCTest
@testable import RecorderCore

final class RecordingModelsTests: XCTestCase {
    func testNativeResolutionRoundsDownToEvenPixels() {
        XCTAssertEqual(CaptureResolution.native.outputSize(for: CGSize(width: 1921, height: 1081)), CGSize(width: 1920, height: 1080))
    }

    func testFullHDScalesWithoutUpscaling() {
        XCTAssertEqual(CaptureResolution.fullHD.outputSize(for: CGSize(width: 3840, height: 2160)), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(CaptureResolution.fullHD.outputSize(for: CGSize(width: 800, height: 600)), CGSize(width: 800, height: 600))
        XCTAssertEqual(CaptureResolution.fullHD.outputSize(for: CGSize(width: 2160, height: 3840)), CGSize(width: 606, height: 1080))
    }

    func test640ResolutionPreservesAspectAndNeverUpscales() {
        XCTAssertEqual(CaptureResolution.compact.outputSize(for: CGSize(width: 1920, height: 1080)), CGSize(width: 640, height: 360))
        XCTAssertEqual(CaptureResolution.compact.outputSize(for: CGSize(width: 800, height: 600)), CGSize(width: 640, height: 480))
        XCTAssertEqual(CaptureResolution.compact.outputSize(for: CGSize(width: 1080, height: 1920)), CGSize(width: 270, height: 480))
        XCTAssertEqual(CaptureResolution.compact.outputSize(for: CGSize(width: 320, height: 240)), CGSize(width: 320, height: 240))
    }

    func testQualityBudgetsDecreaseAndRespectSourceBitrate() {
        let size = CGSize(width: 1920, height: 1080)
        let rates = ExportQuality.allCases.map { $0.videoBitRate(size: size, frameRate: 30, codec: .h264, sourceBitRate: 2_000_000, sourceSize: size) }
        XCTAssertGreaterThan(rates[0], rates[1])
        XCTAssertGreaterThan(rates[1], rates[2])
        XCTAssertLessThanOrEqual(rates[0], 2_000_000)
        let cropped = ExportQuality.balanced.videoBitRate(size: CGSize(width: 960, height: 540), frameRate: 30,
            codec: .h264, sourceBitRate: 2_000_000, sourceSize: size)
        XCTAssertLessThanOrEqual(cropped, 400_000)
    }

    func testEstimateIncludesAudioAndScalesWithDuration() {
        let silent = ExportQuality.balanced.estimatedBytes(duration: 60, videoBitRate: 1_000_000, hasAudio: false)
        let audio = ExportQuality.balanced.estimatedBytes(duration: 60, videoBitRate: 1_000_000, hasAudio: true)
        XCTAssertGreaterThan(audio, silent)
        XCTAssertEqual(audio, 8_713_800)
        XCTAssertEqual(ExportQuality.balanced.estimatedBytes(duration: 30, videoBitRate: 1_000_000, hasAudio: true), audio / 2)
    }

    func testContainerCompatibilityAndSharedEncoderArguments() {
        XCTAssertFalse(VideoCodec.h264.containers.contains(.webm))
        XCTAssertTrue(VideoCodec.vp9.containers.contains(.webm))
        let settings = TranscodeSettings(crop: CGRect(x: 12, y: 14, width: 1200, height: 800),
            outputSize: CGSize(width: 640, height: 426), trim: TrimRange(start: 1.5, end: 4), codec: .vp9,
            container: .webm, videoBitRate: 400_000, audioBitRate: 64_000, audioTrackCount: 2, frameRate: 30)
        let input = URL(fileURLWithPath: "/tmp/a file; $(echo no).mp4")
        let args = settings.arguments(input: input, output: URL(fileURLWithPath: "/tmp/out.webm"))
        XCTAssertTrue(args.contains(input.path))
        XCTAssertTrue(args.contains("libopus"))
        XCTAssertTrue(args.contains("400000"))
        XCTAssertTrue(args.contains { $0.contains("crop=1200:800:12:14:exact=1,scale=640:426") })
        XCTAssertTrue(args.contains { $0.contains("amix=inputs=2") })
    }

    func testCropCoordinatesAndEvenDimensions() throws {
        let rect = try CropMargins(left: 11, top: 13, right: 20, bottom: 30).rect(in: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(rect, CGRect(x: 11, y: 13, width: 1888, height: 1036))
    }

    func testInvalidCropIsRejected() {
        for margins in [CropMargins(left: -1), CropMargins(left: 99), CropMargins(top: .nan), CropMargins(right: .infinity)] {
            XCTAssertThrowsError(try margins.rect(in: CGSize(width: 100, height: 100)))
        }
    }

    func testSelectionClampsToVideoBounds() throws {
        let size = CGSize(width: 100, height: 80)
        let crop = CropMargins.from(rect: CGRect(x: -20, y: 10, width: 80, height: 90), in: size)
        XCTAssertEqual(crop, CropMargins(left: 0, top: 10, right: 40, bottom: 0))
        XCTAssertEqual(try crop.rect(in: size), CGRect(x: 0, y: 10, width: 60, height: 70))
    }

    func testTimeRangeValidation() throws {
        try TrimRange(start: 0, end: 10).validate(duration: 10)
        try TrimRange(start: 1.25, end: 4.5).validate(duration: 10)
        for range in [TrimRange(start: -1, end: 2), TrimRange(start: 2, end: 2),
                      TrimRange(start: 4, end: 3), TrimRange(start: 0, end: 11), TrimRange(start: .nan, end: 2)] {
            XCTAssertThrowsError(try range.validate(duration: 10))
        }
    }

    func testNamingNeverOverwritesExistingFiles() {
        let directory = URL(fileURLWithPath: "/tmp/recordings")
        let url = RecordingFiles.uniqueURL(directory: directory, stem: "sample", container: .mp4) {
            ["sample.mp4", "sample-1.mp4"].contains($0.lastPathComponent)
        }
        XCTAssertEqual(url.lastPathComponent, "sample-2.mp4")
    }

    func testRecordingGates() {
        XCTAssertTrue(RecordingPhase.ready.canStart)
        XCTAssertFalse(RecordingPhase.recording.canStart)
        XCTAssertTrue(RecordingPhase.recording.canStop)
        XCTAssertFalse(RecordingPhase.stopping.canStop)
        XCTAssertTrue(RecordingPhase.starting.isBusy)
        XCTAssertFalse(RecordingPhase.ready.isBusy)
    }

    func testDurationFormatting() {
        XCTAssertEqual(timeLabel(3661), "01:01:01")
        XCTAssertEqual(timeLabel(-1), "00:00:00")
        XCTAssertEqual(timeLabel(.nan), "00:00:00")
    }
}
