import AppKit
import AVKit
import SwiftUI
import RecorderCore

struct MainView: View {
    @EnvironmentObject private var language: LanguageSettings
    @ObservedObject var capture: CaptureService
    @ObservedObject var editor: VideoEditor
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "record.circle.fill").font(.system(size: 30)).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ScreenRecorder").font(.title2.bold())
                    Text(L10n.text("Record, crop, save. Everything stays on your Mac.", "录制、裁剪、保存。全部在本机完成。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L10n.text("Workspace", "工作区"), selection: $page) {
                    Text(L10n.text("Record", "录制")).tag(0)
                    Text(L10n.text("Edit / Convert / Compress", "视频编辑 / 转码 / 压缩")).tag(1)
                }.pickerStyle(.segmented).frame(width: 340)
                    .disabled(capture.phase.isBusy || editor.exporting || editor.loading)
                Picker("Language / 语言", selection: Binding(get: { language.selection }, set: language.select)) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 125)
                .accessibilityLabel("Language / 语言")
            }.padding(20)
            Divider()
            if page == 0 {
                RecordingView(capture: capture)
            } else {
                EditingView(editor: editor)
            }
        }
        .frame(minWidth: 1060, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(L10n.text("ScreenRecorder · Record", "ScreenRecorder · 录屏"))
        .onChange(of: capture.completedRecording) { _, result in
            guard let result else { return }
            Task {
                page = 1
                await editor.openRecording(result)
            }
        }
        .onChange(of: page) { _, page in
            if page == 1 { Task { await capture.releasePreview() } }
            else { editor.player.pause() }
        }
    }
}

private struct RecordingView: View {
    @EnvironmentObject private var language: LanguageSettings
    @ObservedObject var capture: CaptureService

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ForEach(RecordingSource.allCases) { source in
                    Button {
                        switch source {
                        case .area: Task { await capture.chooseScreenRegion() }
                        case .display: capture.chooseDisplay()
                        case .window: capture.chooseWindow()
                        }
                    } label: {
                        Label(source.title, systemImage: source.systemImage)
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .tint(capture.sourceMode == source ? .accentColor : .secondary)
                    .disabled(capture.phase.isBusy)
                }
            }.padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(capture.phaseTitle, systemImage: capture.phase == .recording ? "record.circle.fill" : "display")
                            .foregroundStyle(capture.phase == .recording ? .red : .primary).lineLimit(1)
                        Spacer()
                        if capture.sourceSize.width > 0 {
                            Text("\(Int(capture.sourceSize.width)) × \(Int(capture.sourceSize.height)) px")
                                .foregroundStyle(.secondary).font(.caption.monospacedDigit())
                        }
                    }
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.92))
                        if let image = capture.preview {
                            Image(decorative: image, scale: 1).resizable().scaledToFit().padding(1)
                        } else {
                            VStack(spacing: 14) {
                                Image(systemName: "viewfinder").font(.system(size: 48, weight: .light))
                                Text(L10n.text("Choose Area, Screen, or Window above", "从上方选择区域、屏幕或窗口"))
                                    .font(.title3)
                                Text(L10n.text("Area opens a desktop selection overlay", "选择“区域”即可在桌面拖框"))
                                    .font(.callout).foregroundStyle(.gray)
                            }.foregroundStyle(.white.opacity(0.8))
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    HStack {
                        Text(timeLabel(capture.elapsed)).font(.system(size: 30, weight: .medium, design: .monospaced))
                        Spacer()
                        if capture.recordedBytes > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(capture.recordedBytes), countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if capture.captureRegion != nil {
                        Text(L10n.text("Recording only the selected area. Choose Area again to redraw, or Screen for a full display.",
                                       "仅录制选框内画面。再次选择“区域”可重画，选择“屏幕”可录制整屏。"))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let message = capture.message { StatusMessage(text: message) }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 8) {
                                sectionTitle(L10n.text("File format", "存储格式"), systemImage: "film")
                                Picker(L10n.text("Codec", "编码"), selection: $capture.codec) {
                                    ForEach(MediaFormats.recordingCodecs) { Text($0.title).tag($0) }
                                }.id(language.selection)
                                Picker(L10n.text("Container", "容器"), selection: $capture.container) {
                                    ForEach(MediaFormats.recordingContainers(for: capture.codec)) { Text($0.title).tag($0) }
                                }.id(language.selection)
                                Picker(L10n.text("Resolution", "分辨率"), selection: $capture.resolution) {
                                    ForEach(CaptureResolution.allCases) { Text($0.title).tag($0) }
                                }.id(language.selection)
                                Text(L10n.text("30 fps · SDR · Show cursor", "30 fps · SDR · 显示鼠标指针"))
                                    .font(.caption).foregroundStyle(.secondary)
                                if !MediaFormats.canRecordDirectly(codec: capture.codec, container: capture.container) {
                                    Text(L10n.text("Converts after recording; the original is kept.", "停止后转换格式，保留原始录屏。"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if MediaFormats.exportCodecs.isEmpty {
                                    Text(L10n.text("Install FFmpeg for more formats and editing.", "安装 FFmpeg 后可使用更多格式和编辑功能。"))
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                sectionTitle(L10n.text("Audio", "声音"), systemImage: "waveform")
                                Toggle(L10n.text("Record source audio", "录制来源音频"), isOn: $capture.sourceAudio)
                                Toggle(L10n.text("Record microphone", "录制麦克风"), isOn: $capture.microphone)
                                if capture.microphone {
                                    Picker(L10n.text("Device", "设备"), selection: $capture.microphoneID) {
                                        Text(L10n.text("System default microphone", "系统默认麦克风")).tag("")
                                        ForEach(capture.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                                    }
                                }
                                Text(L10n.text("Audio follows the shared source, including when recording an area.", "声音跟随共享来源，区域录屏也不会按选框隔离音频。"))
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }.padding(16).disabled(capture.phase.isBusy)
                    }.frame(maxHeight: .infinity)
                    Divider()
                    recordingControls.padding(16)
                }.frame(width: 300)
            }.frame(maxHeight: .infinity)
        }
        .onChange(of: capture.codec) { _, codec in
            if !MediaFormats.recordingContainers(for: codec).contains(capture.container) {
                capture.container = MediaFormats.recordingContainers(for: codec).first ?? .mp4
            }
        }
        .sheet(item: Binding(get: { capture.sourceChooser }, set: { value in
            if value == nil, capture.sourceChooser != nil { capture.cancelSourceSelection() }
        })) { chooser in
            SourceSelectionView(model: chooser,
                                confirm: { Task { await capture.confirmDirectSource() } },
                                cancel: { capture.cancelSourceSelection() },
                                useSystemPicker: { capture.useSystemSourcePicker() })
        }
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(capture.directory.path).font(.caption).lineLimit(1).truncationMode(.middle)
                    .help(capture.directory.path)
                Spacer(minLength: 0)
                Button(L10n.text("Change…", "更改…")) { capture.chooseDirectory() }
                    .disabled(capture.phase.isBusy)
                    .accessibilityLabel(L10n.text("Change save folder", "更改保存目录"))
            }
            if capture.phase == .selecting || capture.phase == .selectingRegion {
                Button(L10n.text("Cancel selection", "取消选择")) { capture.cancelSourceSelection() }
                    .frame(maxWidth: .infinity).controlSize(.large)
            } else if capture.phase == .recording || capture.phase == .starting {
                Button(role: .destructive) { Task { await capture.stop() } } label: {
                    Label(L10n.text("Stop and save", "停止并保存"), systemImage: "stop.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            } else {
                Button { Task { await capture.start() } } label: {
                    Label(capture.phase == .stopping ? L10n.text("Saving…", "正在保存…") : L10n.text("Start recording", "开始录制"),
                          systemImage: "record.circle").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large).disabled(!capture.phase.canStart)
            }
            if capture.phase == .stopping || capture.phase == .preparing { ProgressView().controlSize(.small) }
            Button(L10n.text("Screen Recording permissions", "屏幕录制权限设置")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }.font(.caption).buttonStyle(.link)
        }
    }
}

private struct EditingView: View {
    @EnvironmentObject private var language: LanguageSettings
    @ObservedObject var editor: VideoEditor
    @State private var showCrop = true

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(editor.sourceURL?.lastPathComponent ?? L10n.text("Open a video to edit, convert, or compress", "打开本地视频，编辑 / 转码 / 压缩"), systemImage: "film")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L10n.text("Import video…", "导入视频…")) { Task { await editor.importVideo() } }
                        .disabled(editor.exporting || editor.loading)
                    Button(L10n.text("New project", "新建项目")) { editor.newProject() }
                        .disabled(editor.exporting || editor.loading)
                }
                if !editor.sources.isEmpty {
                    Picker(L10n.text("Source video", "原始视频"), selection: Binding(get: { editor.currentSourceID }, set: { id in
                        if let id { Task { await editor.selectSource(id) } }
                    })) {
                        ForEach(editor.sources) { source in Text(source.name).tag(Optional(source.id)) }
                    }.disabled(editor.exporting || editor.loading)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.black)
                    if editor.hasVideo {
                        if editor.nativePlayback {
                            PlayerView(player: editor.player)
                        } else if let image = editor.thumbnail {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else {
                            Text(L10n.text("Video loaded and ready to edit. This format does not support native playback.", "视频已载入，可裁剪或转码。当前格式不支持原生播放。"))
                                .foregroundStyle(.white).padding()
                        }
                        if showCrop {
                            CropOverlay(size: editor.size, crop: $editor.crop)
                                .allowsHitTesting(!editor.exporting)
                        }
                    } else if editor.loading {
                        ProgressView(L10n.text("Reading video…", "正在读取视频…")).tint(.white).foregroundStyle(.white)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "crop.rotate").font(.system(size: 48, weight: .light))
                            Text(L10n.text("Edit a completed recording here, or import a local video.", "录制结束后在这里裁剪，或导入本地视频。"))
                        }.foregroundStyle(.white.opacity(0.8))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                HStack {
                    Button { editor.previewSelection() } label: { Label(L10n.text("Play selection", "播放选中片段"), systemImage: "play.fill") }
                        .disabled(!editor.nativePlayback)
                    Button { editor.player.pause() } label: { Image(systemName: "pause.fill") }
                    Spacer()
                    Toggle(L10n.text("Show crop frame", "显示裁剪框"), isOn: $showCrop).toggleStyle(.checkbox)
                }.disabled(!editor.hasVideo || editor.exporting)
                if editor.hasVideo {
                    Text(L10n.text("Original: \(Int(editor.size.width)) × \(Int(editor.size.height)) · \(ByteCountFormatter.string(fromByteCount: editor.sourceBytes, countStyle: .file))", "原文件：\(Int(editor.size.width)) × \(Int(editor.size.height)) · \(ByteCountFormatter.string(fromByteCount: editor.sourceBytes, countStyle: .file))") +
                         (editor.nativePlayback ? "" : L10n.text(" · Still-frame preview. Adjust the time range to view other frames.", " · 当前格式使用静帧预览，调整起止时间可查看对应画面。")))
                        .font(.caption).foregroundStyle(.secondary)
                }
                GroupBox(L10n.text("Current clip · Time range", "当前片段 · 起止时间")) {
                    VStack(spacing: 10) {
                        timeControl(L10n.text("Start", "开始"), value: $editor.start)
                        timeControl(L10n.text("End", "结束"), value: $editor.end)
                        HStack {
                            Text(L10n.text("Duration \(timeLabel(editor.duration))", "总时长 \(timeLabel(editor.duration))"))
                            Spacer()
                            Text(L10n.text("Selection \(String(format: "%.2f", max(0, editor.end - editor.start))) s", "当前 \(String(format: "%.2f", max(0, editor.end - editor.start))) 秒"))
                        }.font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button { editor.addClip() } label: { Label(L10n.text("Add to clip list", "加入拼接列表"), systemImage: "plus") }
                                .disabled(!editor.validDraft)
                            if editor.editedClipID != nil {
                                Button(L10n.text("Update selected clip", "更新所选片段")) { editor.updateSelectedClip() }.disabled(!editor.validDraft)
                            }
                            Spacer()
                        }
                    }.padding(6)
                }.disabled(!editor.hasVideo || editor.exporting)
                clipList
                if let message = editor.message { StatusMessage(text: message) }
            }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sectionTitle(L10n.text("Crop video", "画面裁剪"), systemImage: "crop")
                        Text(L10n.text("Drag corners to crop, or drag the frame to move it. Drag outside to draw a new frame, or enter pixel margins below.", "拖动四角裁剪，拖动选框移动。框外拖动可重新框选，也可输入各边裁去的像素。"))
                            .font(.caption).foregroundStyle(.secondary)
                        marginControl(L10n.text("Left", "左"), value: $editor.crop.left)
                        marginControl(L10n.text("Top", "上"), value: $editor.crop.top)
                        marginControl(L10n.text("Right", "右"), value: $editor.crop.right)
                        marginControl(L10n.text("Bottom", "下"), value: $editor.crop.bottom)
                        Button(L10n.text("Reset crop and time", "重置画面与时间")) {
                            editor.crop = CropMargins()
                            editor.start = 0
                            editor.end = editor.duration
                        }.disabled(editor.exporting)
                        if editor.validEdit {
                            Text(L10n.text("Output \(Int(editor.outputSize.width)) × \(Int(editor.outputSize.height)) pixels", "输出 \(Int(editor.outputSize.width)) × \(Int(editor.outputSize.height)) 像素"))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Divider()
                        sectionTitle(L10n.text("Export settings", "导出设置"), systemImage: "square.and.arrow.up")
                        Picker(L10n.text("Codec", "编码"), selection: $editor.codec) {
                            ForEach(VideoCodec.allCases.filter { editor.availableFormats[$0] != nil }) { Text($0.title).tag($0) }
                        }.id(language.selection).disabled(editor.exporting)
                        Picker(L10n.text("Container", "容器"), selection: $editor.container) {
                            ForEach(editor.availableFormats[editor.codec] ?? []) { Text($0.title).tag($0) }
                        }.id(language.selection).disabled(editor.exporting)
                        Picker(L10n.text("Resolution", "分辨率"), selection: $editor.resolution) {
                            ForEach(CaptureResolution.allCases) { Text($0.title).tag($0) }
                        }.id(language.selection).disabled(editor.exporting)
                        Picker(L10n.text("Quality", "画质"), selection: $editor.quality) {
                            ForEach(ExportQuality.allCases) { quality in
                                Text(L10n.text("\(quality.title) · ~\(editor.sizeLabel(for: quality))", "\(quality.title) · 约 \(editor.sizeLabel(for: quality))")).tag(quality)
                            }
                        }.id(language.selection).disabled(editor.exporting)
                        Text(L10n.text("Estimated ~\(editor.sizeLabel(for: editor.quality)) · Video \(String(format: "%.0f", Double(editor.bitRate(for: editor.quality)) / 1000)) kb/s", "预计约 \(editor.sizeLabel(for: editor.quality)) · 视频 \(String(format: "%.0f", Double(editor.bitRate(for: editor.quality)) / 1000)) kb/s"))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(L10n.text("Estimated from target bitrate and duration. Actual size varies with content. High quality may produce a larger file than the original.", "按目标码率和所选时长估算，实际大小随画面内容变化。高画质不保证小于原文件。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(editor.clips.isEmpty
                             ? L10n.text("With no clips listed, exports the current selection. Keep the full frame and duration to convert the entire video.", "未添加片段时，导出当前画面的起止时间段；也可保持完整画面和时长直接转码。")
                             : L10n.text("Exports listed clips from top to bottom. The first clip and resolution set the canvas; other clips fit with black bars as needed.", "只导出拼接列表，按从上到下的顺序合成。输出尺寸由首段及分辨率设置决定，其余片段等比缩放，必要时补黑边。"))
                            .font(.caption).foregroundStyle(.secondary)
                        if !editor.validEdit && editor.hasVideo {
                            Text(L10n.text("Check the crop and time range.", "请检查裁剪范围和起止时间。"))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }.padding(20)
                }
                Divider()
                exportControls.padding(20)
            }.frame(width: 300).disabled(!editor.hasVideo)
        }
        .onChange(of: editor.codec) { _, codec in
            if !(editor.availableFormats[codec] ?? []).contains(editor.container) {
                editor.container = editor.availableFormats[codec]?.first ?? .mp4
            }
        }
    }

    private var clipList: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.text("Clip list · \(editor.clips.count) · \(String(format: "%.2f", editor.clips.isEmpty ? 0 : editor.exportDuration)) s total", "拼接列表 · \(editor.clips.count) 段 · 共 \(String(format: "%.2f", editor.clips.isEmpty ? 0 : editor.exportDuration)) 秒"))
                        .font(.caption.bold())
                    Spacer()
                    if !editor.clips.isEmpty { Button(L10n.text("Clear list", "清空列表")) { editor.clearClips() }.font(.caption) }
                }
                if editor.clips.isEmpty {
                    Text(L10n.text("Import videos, select a time range, then click “Add to clip list”. You can add multiple, overlapping, or repeated clips from one video.", "导入一个或多个视频，选择时间段后点击“加入拼接列表”。同一视频可添加多段，允许重复及重叠。"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(editor.clips.enumerated()), id: \.element.id) { index, clip in
                                HStack(spacing: 6) {
                                    Text("\(index + 1)").font(.caption.monospacedDigit()).frame(width: 20)
                                    Button { Task { await editor.editClip(clip.id) } } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(clip.name).lineLimit(1).truncationMode(.middle)
                                            Text(String(format: L10n.text("%.2f → %.2f s · %.2f s", "%.2f → %.2f 秒 · %.2f 秒"), clip.trim.start, clip.trim.end, clip.duration))
                                                .foregroundStyle(.secondary).monospacedDigit()
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain)
                                    Button { editor.moveClip(clip.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                                        .disabled(index == 0).help(L10n.text("Move up", "向前移动"))
                                    Button { editor.moveClip(clip.id, offset: 1) } label: { Image(systemName: "arrow.down") }
                                        .disabled(index == editor.clips.count - 1).help(L10n.text("Move down", "向后移动"))
                                    Button { editor.removeClip(clip.id) } label: { Image(systemName: "minus.circle") }
                                        .help(L10n.text("Remove clip", "移除片段"))
                                }.font(.caption).padding(6)
                                    .background(editor.editedClipID == clip.id ? Color.accentColor.opacity(0.12) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }.frame(height: min(130, CGFloat(editor.clips.count) * 48))
                    Text(L10n.text("Click a clip to edit it, then click “Update selected clip”. Clips export in list order.", "点击片段可修改，修改后点“更新所选片段”；列表顺序就是导出顺序。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }.disabled(editor.exporting || editor.loading)
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editor.exporting {
                ProgressView(value: Double(editor.progress))
                Text(L10n.text("Exporting \(Int(editor.progress * 100))%", "正在导出 \(Int(editor.progress * 100))%"))
                    .font(.caption.monospacedDigit())
                Button(L10n.text("Cancel export", "取消导出"), role: .destructive) { editor.cancelExport() }
            } else {
                Button {
                    guard let url = editor.savePanel() else { return }
                    Task { await editor.export(to: url) }
                } label: {
                    Label(editor.clips.isEmpty ? L10n.text("Export current clip…", "导出当前片段…") : L10n.text("Export joined video…", "导出拼接视频…"), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!editor.validEdit || editor.availableFormats.isEmpty)
            }
            if let url = editor.exportedURL {
                Button(L10n.text("Show in Finder", "在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    private func timeControl(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 40, alignment: .leading)
            Slider(value: value, in: 0...max(0.01, editor.duration)) { editing in
                if !editing { editor.seek(value.wrappedValue) }
            }
            TextField(L10n.text("s", "秒"), value: value, format: .number.precision(.fractionLength(2)))
                .frame(width: 80).textFieldStyle(.roundedBorder)
                .onSubmit { editor.seek(value.wrappedValue) }
            Text(L10n.text("s", "秒")).foregroundStyle(.secondary)
        }
    }

    private func marginControl(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(L10n.text("Pixels", "像素"), value: value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder).frame(width: 115)
            Text("px").foregroundStyle(.secondary)
        }.disabled(editor.exporting)
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

private struct StatusMessage: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private func sectionTitle(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage).font(.headline)
}
