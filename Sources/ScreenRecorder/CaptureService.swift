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
    @Published private(set) var captureRegion: CaptureRegion?
    @Published private(set) var completedRecording: CompletedRecording?
    @Published private var status: LocalizedMessage?
    var message: String? { status?.text() }
    var phaseTitle: String {
        if phase == .selecting, let requestedSource {
            return requestedSource == .window
                ? L10n.text("Choose a window", "请选择窗口")
                : L10n.text("Choose a display", "请选择屏幕")
        }
        return phase.title
    }
    @Published private(set) var sourceMode: RecordingSource?
    @Published private(set) var sourceChooser: SourceSelectionModel?

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
    private let regionSelector = ScreenRegionSelector()
    private var requestedSource: RecordingSource?
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

    func chooseDisplay() { chooseSource(.display) }
    func chooseWindow() { chooseSource(.window) }

    private func chooseSource(_ source: RecordingSource) {
        guard !phase.isBusy else { return }
        status = nil
        // ScreenCaptureKit is the authority for its own access. A CoreGraphics
        // preflight can disagree with an existing ScreenCaptureKit grant.
        requestedSource = source
        phase = .selecting
        sourceChooser = SourceSelectionModel(mode: source) { try await DirectCaptureSources.options(for: source) }
    }

    func confirmDirectSource() async {
        guard phase == .selecting, let chooser = sourceChooser, chooser.canConfirm,
              let option = chooser.selectedOption else { return }
        chooser.confirming = true
        defer { chooser.confirming = false }
        do {
            let selected = try await DirectCaptureSources.resolve(option, mode: chooser.mode)
            guard sourceChooser === chooser, phase == .selecting else { return }
            requestedSource = nil
            sourceChooser = nil
            await prepare(selected, mode: chooser.mode)
        } catch {
            guard sourceChooser === chooser, phase == .selecting else { return }
            chooser.error = CaptureFailure.message(for: error)
            if let sourceError = error as? SourceSelectionError, case .unavailable = sourceError {
                chooser.selectedID = nil
            }
        }
    }

    func useSystemSourcePicker() {
        guard phase == .selecting, let chooser = sourceChooser else { return }
        chooser.cancel()
        sourceChooser = nil
        presentPicker(for: chooser.mode)
    }

    private func presentPicker(for source: RecordingSource) {
        requestedSource = source
        phase = .selecting
        let picker = SCContentSharingPicker.shared
        var options = picker.defaultConfiguration
        options.allowedPickerModes = source == .window ? [.singleWindow] : [.singleDisplay]
        options.allowsChangingSelectedContent = true
        picker.defaultConfiguration = options
        picker.isActive = true
        let style: SCShareableContentStyle = source == .window ? .window : .display
        if let stream {
            // A live preview already occupies the single allowed stream. Ask to
            // replace that stream instead of requesting a second one.
            picker.setConfiguration(options, for: stream)
            picker.present(for: stream, using: style)
        } else {
            picker.present(using: style)
        }
    }

    func chooseScreenRegion() async {
        guard !phase.isBusy else { return }
        status = nil
        requestedSource = nil
        phase = .selectingRegion
        // Show the desktop overlay first, independently of capture permission.
        let selection = await regionSelector.select()
        guard phase == .selectingRegion else { return }
        guard let selection else { restoreSelectionState(); return }
        if #available(macOS 15.2, *), stream != nil, let filter, filter.style == .display,
           filter.includedDisplays.contains(where: { $0.displayID == selection.displayID }) {
            await prepareRegion(selection, filter: filter)
            return
        }
        await prepareDirectRegion(selection)
    }

    private func prepareRegion(_ selection: ScreenRegionSelector.Selection, filter selected: SCContentFilter) async {
        do {
            let region = try CaptureRegion(appKitRect: selection.appKitRect, displaySize: selection.displaySize,
                                           pixelScale: CGFloat(selected.pointPixelScale))
            selected.includeMenuBar = true
            await prepare(selected, mode: .area, region: region)
        } catch {
            restoreSelectionState()
            status = LocalizedMessage(error: error)
        }
    }

    private func prepareDirectRegion(_ selection: ScreenRegionSelector.Selection) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard phase == .selectingRegion else { return }
            guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
                throw ValidationError.invalidCaptureRegion
            }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let selected = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            await prepareRegion(selection, filter: selected)
        } catch {
            guard phase == .selectingRegion else { return }
            restoreSelectionState()
            status = CaptureFailure.message(for: error)
        }
    }

    func cancelSourceSelection() {
        guard phase == .selecting || phase == .selectingRegion else { return }
        regionSelector.cancel()
        sourceChooser?.cancel()
        sourceChooser = nil
        SCContentSharingPicker.shared.isActive = false
        restoreSelectionState()
        status = nil
    }

    private func restoreSelectionState() {
        requestedSource = nil
        if let stream { lockPickerChanges(for: stream) }
        phase = stream == nil ? .idle : .ready
    }

    private func lockPickerChanges(for stream: SCStream) {
        var options = SCContentSharingPicker.shared.defaultConfiguration
        options.allowsChangingSelectedContent = false
        SCContentSharingPicker.shared.setConfiguration(options, for: stream)
    }

    func useFullDisplay() async {
        guard !phase.isBusy, captureRegion != nil, let filter else { return }
        await prepare(filter, mode: .display)
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.prompt = L10n.text("Choose save folder", "选择保存目录")
        if panel.runModal() == .OK, let url = panel.url { directory = url }
    }

    private func configuration(recording: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let size = resolution.outputSize(for: sourceSize)
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        if let captureRegion { configuration.sourceRect = captureRegion.sourceRect }
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

    private func prepare(_ selected: SCContentFilter, mode: RecordingSource, region: CaptureRegion? = nil) async {
        phase = .preparing
        let previous = stream
        stream = nil
        if let previous { try? await previous.stopCapture() }
        preview = nil
        filter = selected
        captureRegion = region
        sourceMode = mode
        sourceSize = region?.pixelSize ?? CGSize(width: selected.contentRect.width * CGFloat(selected.pointPixelScale),
                                                height: selected.contentRect.height * CGFloat(selected.pointPixelScale))
        guard sourceSize.width >= 2, sourceSize.height >= 2 else {
            phase = .idle
            status = LocalizedMessage("The selected window has no recordable content. Choose another source.", "所选窗口没有可录制的画面，请重新选择。")
            return
        }
        let output = PreviewOutput()
        let capture = SCStream(filter: selected, configuration: configuration(recording: false), delegate: self)
        lockPickerChanges(for: capture)
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
            filter = nil
            captureRegion = nil
            sourceMode = nil
            sourceSize = .zero
            status = CaptureFailure.message(for: error)
        }
    }

    func start() async {
        guard phase.canStart, let stream else { return }
        phase = .starting
        status = nil
        completedRecording = nil
        elapsed = 0
        recordedBytes = 0
        do {
            if microphone {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else {
                    throw NSError(domain: "ScreenRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        L10n.text("Microphone access is disabled. Allow ScreenRecorder in System Settings → Privacy & Security → Microphone.", "麦克风权限未开启。请在系统设置 → 隐私与安全性 → 麦克风中允许 ScreenRecorder。")])
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
            status = LocalizedMessage(error: error)
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
            status = LocalizedMessage("Error stopping recording: \(LocalizedMessage(error: error).english)", "停止录制时发生错误：\(LocalizedMessage(error: error).chinese)")
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
            status = LocalizedMessage("Recording did not start in time and was stopped. Select the source again.", "录制未能及时启动，已停止。请重新选择来源。")
            Task { await stop() }
        }
        if phase == .recording {
            do { try RecordingFiles.checkDestination(directory, minimumBytes: 50 * 1024 * 1024) }
            catch {
                status = LocalizedMessage(error: error) + LocalizedMessage(" Recording stopped and a save was attempted.", " 已停止录制并尝试保存。")
                Task { await stop() }
            }
        }
    }

    private func scheduleFinalizationTimeout() {
        guard phase == .stopping, finalizationTask == nil else { return }
        finalizationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.phase == .stopping else { return }
            self.status = LocalizedMessage("Recording could not finish normally. The original file has been kept at: \(self.recordingURL?.path ?? "")", "录制文件未能正常完成。已保留原始文件，请检查：\(self.recordingURL?.path ?? "")")
            self.finishCapture()
        }
    }

    private func finishCapture() {
        regionSelector.cancel()
        sourceChooser?.cancel()
        sourceChooser = nil
        requestedSource = nil
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
        captureRegion = nil
        sourceMode = nil
        sourceSize = .zero
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
        if let error { status = LocalizedMessage("Recording source interrupted: \(LocalizedMessage(error: error).english)", "录制来源已中断：\(LocalizedMessage(error: error).chinese)") }
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
            guard self.phase == .selecting, self.sourceChooser == nil else { return }
            self.restoreSelectionState()
            self.status = nil
            if self.stream == nil { SCContentSharingPicker.shared.isActive = false }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            guard self.phase == .selecting, self.sourceChooser == nil, let mode = self.requestedSource else { return }
            self.requestedSource = nil
            guard (mode == .window && filter.style == .window) || (mode == .display && filter.style == .display) else {
                self.restoreSelectionState()
                return
            }
            await self.prepare(filter, mode: mode)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            guard self.phase == .selecting, self.sourceChooser == nil else { return }
            self.restoreSelectionState()
            self.status = LocalizedMessage(error: error)
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
                userInfo: [NSLocalizedDescriptionKey: L10n.text("The target window closed or the recording source is unavailable. A save was attempted. ", "目标窗口已关闭或录制来源不可用。已尝试保存录制。 ")]))
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
            self.status = LocalizedMessage("Recording failed: \(LocalizedMessage(error: error).english)\nAny data already written has been kept at: \(path)", "录制失败：\(LocalizedMessage(error: error).chinese)\n如有已写入的数据，文件保留在：\(path)")
            try? await capture?.stopCapture()
        }
    }
}
