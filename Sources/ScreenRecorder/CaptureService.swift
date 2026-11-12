import AppKit
import AVFoundation
import Combine
import CoreImage
import RecorderCore
import ScreenCaptureKit

/// Converts only a few preview frames per second. The recording itself stays in ScreenCaptureKit.
private final class PreviewOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var lastFrame = 0.0
    var onFrame: ((CGImage) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let now = ProcessInfo.processInfo.systemUptime
        guard type == .screen, now - lastFrame >= 0.2,
              sampleBuffer.isValid, let buffer = sampleBuffer.imageBuffer else { return }
        lastFrame = now
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 960 / image.extent.width)
        let thumbnail = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let frame = context.createCGImage(thumbnail, from: thumbnail.extent) { onFrame?(frame) }
    }
}

@MainActor
final class CaptureService: NSObject, ObservableObject {
    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var preview: CGImage?
    @Published private(set) var elapsed = 0.0
    @Published private(set) var recordedBytes: Int = 0
    @Published private(set) var sourceSize = CGSize.zero
    @Published private(set) var completedRecording: CompletedRecording?
    @Published var message: String?

    @Published var codec: VideoCodec = .h264
    @Published var container: VideoContainer = .mp4
    @Published var resolution: CaptureResolution = .native
    @Published var sourceAudio = false
    @Published var microphone = false
    @Published var microphoneID = ""
    @Published var directory: URL {
        didSet { UserDefaults.standard.set(directory.path, forKey: "recordingDirectory") }
    }

    private var filter: SCContentFilter?
    private var stream: SCStream?
    private var previewOutput: PreviewOutput?
    private var recordingOutput: SCRecordingOutput?
    private var recordingURL: URL?
    private var recordingPlan: CompletedRecording?
    private var timer: Timer?
    private var startingAt: Date?
    private var finalizationTask: Task<Void, Never>?
    private let frameQueue = DispatchQueue(label: "ScreenRecorder.preview", qos: .utility)

    override init() {
        let saved = UserDefaults.standard.string(forKey: "recordingDirectory")
        directory = saved.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/ScreenRecorder", isDirectory: true)
        super.init()
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        configuration.allowsChangingSelectedContent = false
        if let bundle = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [bundle] }
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.add(self)
    }

    var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    func chooseSource() {
        guard !phase.isBusy else { return }
        message = nil
        phase = .selecting
        SCContentSharingPicker.shared.isActive = true
        SCContentSharingPicker.shared.present()
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.prompt = "选择保存目录"
        if panel.runModal() == .OK, let url = panel.url { directory = url }
    }

    private func configuration(recording: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let size = resolution.outputSize(for: sourceSize)
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 4
        configuration.showsCursor = true
        configuration.scalesToFit = true
        configuration.captureDynamicRange = .SDR
        configuration.capturesAudio = recording && sourceAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        configuration.captureMicrophone = recording && microphone
        configuration.microphoneCaptureDeviceID = microphoneID.isEmpty ? nil : microphoneID
        return configuration
    }

    private func prepare(_ selected: SCContentFilter) async {
        phase = .preparing
        if let stream { try? await stream.stopCapture() }
        stream = nil
        preview = nil
        filter = selected
        sourceSize = CGSize(width: selected.contentRect.width * CGFloat(selected.pointPixelScale),
                            height: selected.contentRect.height * CGFloat(selected.pointPixelScale))
        guard sourceSize.width >= 2, sourceSize.height >= 2 else {
            phase = .idle
            message = "所选窗口没有可录制的画面，请重新选择。"
            return
        }
        let output = PreviewOutput()
        let capture = SCStream(filter: selected, configuration: configuration(recording: false), delegate: self)
        output.onFrame = { [weak self, weak capture] image in
            Task { @MainActor in
                guard let self, let capture, self.stream === capture else { return }
                self.preview = image
            }
        }
        do {
            try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: frameQueue)
            stream = capture
            previewOutput = output
            try await capture.startCapture()
            guard stream === capture else { return }
            phase = .ready
        } catch {
            stream = nil
            previewOutput = nil
            phase = .idle
            message = "无法捕获画面：\(error.localizedDescription)\n请在系统设置的“隐私与安全性”中检查屏幕录制权限。"
        }
    }

    func start() async {
        guard phase.canStart, let stream else { return }
        phase = .starting
        message = nil
        completedRecording = nil
        elapsed = 0
        recordedBytes = 0
        do {
            if microphone {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else {
                    throw NSError(domain: "ScreenRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "麦克风权限未开启。请在系统设置 → 隐私与安全性 → 麦克风中允许 ScreenRecorder。"])
                }
            }
            guard self.stream === stream, phase == .starting else { return }
            try RecordingFiles.checkDestination(directory)
            guard MediaFormats.recordingContainers(for: codec).contains(container) else { throw ValidationError.unsupportedFormat }
            let direct = MediaFormats.canRecordDirectly(codec: codec, container: container)
            let stem = RecordingFiles.timestampStem()
            let destination = RecordingFiles.uniqueURL(directory: directory, stem: stem, container: container)
            let url = direct ? destination : RecordingFiles.uniqueURL(directory: directory, stem: stem + "-source", container: .mp4)
            let captureCodec: AVVideoCodecType = direct && codec == .hevc ? .hevc : .h264
            let captureContainer: AVFileType = direct && container == .mov ? .mov : .mp4
            let outputConfiguration = SCRecordingOutputConfiguration()
            guard outputConfiguration.availableVideoCodecTypes.contains(captureCodec),
                  outputConfiguration.availableOutputFileTypes.contains(captureContainer) else {
                throw ValidationError.unsupportedFormat
            }
            outputConfiguration.outputURL = url
            outputConfiguration.videoCodecType = captureCodec
            outputConfiguration.outputFileType = captureContainer
            try await stream.updateConfiguration(configuration(recording: true))
            guard self.stream === stream, phase == .starting else { return }
            let output = SCRecordingOutput(configuration: outputConfiguration, delegate: self)
            recordingURL = url
            recordingPlan = CompletedRecording(source: url, destination: destination, codec: codec, container: container)
            recordingOutput = output
            try stream.addRecordingOutput(output)
            startingAt = Date()
            startTimer()
        } catch {
            recordingOutput = nil
            recordingURL = nil
            recordingPlan = nil
            if self.stream != nil { phase = .ready } else { phase = .idle }
            message = error.localizedDescription
        }
    }

    func stop() async {
        guard phase == .recording || phase == .starting else { return }
        phase = .stopping
        timer?.invalidate()
        timer = nil
        guard let stream else { return }
        do {
            // stopCapture finishes the file; wait for recordingOutputDidFinishRecording before opening it.
            try await stream.stopCapture()
        } catch {
            message = "停止录制时发生错误：\(error.localizedDescription)"
            if let output = recordingOutput { try? stream.removeRecordingOutput(output) }
        }
        if recordingOutput == nil {
            finishCapture()
        } else {
            scheduleFinalizationTimeout()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let output = recordingOutput else { return }
        elapsed = output.recordedDuration.seconds.isFinite ? output.recordedDuration.seconds : 0
        recordedBytes = output.recordedFileSize
        if phase == .starting, let startingAt, Date().timeIntervalSince(startingAt) > 15 {
            message = "录制未能及时启动，已停止。请重新选择来源。"
            Task { await stop() }
        }
        if phase == .recording {
            do { try RecordingFiles.checkDestination(directory, minimumBytes: 50 * 1024 * 1024) }
            catch {
                message = error.localizedDescription + " 已停止录制并尝试保存。"
                Task { await stop() }
            }
        }
    }

    private func scheduleFinalizationTimeout() {
        guard phase == .stopping, finalizationTask == nil else { return }
        finalizationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.phase == .stopping else { return }
            self.message = "录制文件未能正常完成。已保留原始文件，请检查：\(self.recordingURL?.path ?? "")"
            self.finishCapture()
        }
    }

    private func finishCapture() {
        timer?.invalidate()
        timer = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        recordingOutput = nil
        recordingURL = nil
        recordingPlan = nil
        stream = nil
        previewOutput = nil
        preview = nil
        filter = nil
        phase = .idle
        SCContentSharingPicker.shared.isActive = false
    }

    func releasePreview() async {
        guard !phase.isBusy else { return }
        if let stream { try? await stream.stopCapture() }
        finishCapture()
    }

    private func interrupted(_ capture: SCStream, error: Error?) {
        guard stream === capture else { return }
        if let error { message = "录制来源已中断：\(error.localizedDescription)" }
        if recordingOutput != nil {
            phase = .stopping
            timer?.invalidate()
            Task {
                try? await capture.stopCapture()
                scheduleFinalizationTimeout()
            }
        } else {
            finishCapture()
        }
    }
}

extension CaptureService: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            guard self.phase == .selecting else { return }
            self.phase = self.stream == nil ? .idle : .ready
            if self.stream == nil { SCContentSharingPicker.shared.isActive = false }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            guard self.phase == .selecting else { return }
            await self.prepare(filter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            self.phase = self.stream == nil ? .idle : .ready
            self.message = error.localizedDescription
        }
    }
}

extension CaptureService: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.interrupted(stream, error: error) }
    }

    nonisolated func streamDidBecomeInactive(_ stream: SCStream) {
        Task { @MainActor in
            self.interrupted(stream, error: NSError(domain: "ScreenRecorder", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "目标窗口已关闭或录制来源不可用。已尝试保存录制。 "]))
        }
    }
}

extension CaptureService: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard self.recordingOutput === recordingOutput, self.phase == .starting else { return }
            self.phase = .recording
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard self.recordingOutput === recordingOutput else { return }
            let result = self.recordingPlan
            self.finishCapture()
            self.completedRecording = result
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.recordingOutput === recordingOutput else { return }
            let path = self.recordingURL?.path ?? ""
            let capture = self.stream
            self.finishCapture()
            self.message = "录制失败：\(error.localizedDescription)\n如有已写入的数据，文件保留在：\(path)"
            try? await capture?.stopCapture()
        }
    }
}
