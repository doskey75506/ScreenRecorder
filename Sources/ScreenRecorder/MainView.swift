import AppKit
import AVKit
import SwiftUI
import RecorderCore

struct MainView: View {
    @ObservedObject var capture: CaptureService
    @ObservedObject var editor: VideoEditor
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "record.circle.fill").font(.system(size: 30)).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ScreenRecorder").font(.title2.bold())
                    Text("录制、裁剪、保存。全部在本机完成。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("工作区", selection: $page) {
                    Text("录制").tag(0)
                    Text("视频编辑 / 转码 / 压缩").tag(1)
                }.pickerStyle(.segmented).frame(width: 290)
                    .disabled(capture.phase.isBusy || editor.exporting || editor.loading)
            }.padding(20)
            Divider()
            if page == 0 {
                RecordingView(capture: capture)
            } else {
                EditingView(editor: editor)
            }
        }
        .frame(minWidth: 920, minHeight: 730)
        .background(Color(nsColor: .windowBackgroundColor))
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
    @ObservedObject var capture: CaptureService

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(capture.phase.title, systemImage: capture.phase == .recording ? "record.circle.fill" : "display")
                        .foregroundStyle(capture.phase == .recording ? .red : .primary)
                    Spacer()
                    if capture.sourceSize.width > 0 {
                        Text("\(Int(capture.sourceSize.width)) × \(Int(capture.sourceSize.height))")
                            .foregroundStyle(.secondary).font(.caption.monospacedDigit())
                    }
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.92))
                    if let image = capture.preview {
                        Image(decorative: image, scale: 1).resizable().scaledToFit().padding(1)
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "macwindow.on.rectangle").font(.system(size: 48, weight: .light))
                            Text("选择你要录制的画面").font(.title3)
                            Text("显示器或单个应用窗口").font(.callout).foregroundStyle(.gray)
                        }.foregroundStyle(.white.opacity(0.8))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                HStack {
                    Text(timeLabel(capture.elapsed)).font(.system(size: 32, weight: .medium, design: .monospaced))
                    Spacer()
                    if capture.recordedBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(capture.recordedBytes), countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("标签页：将目标标签页移到独立浏览器窗口，再选择该窗口。录制后可裁掉浏览器边框。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message = capture.message { StatusMessage(text: message) }
            }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sectionTitle("录制来源", systemImage: "rectangle.on.rectangle")
                    Button { capture.chooseSource() } label: {
                        Label(capture.phase == .ready ? "重新选择来源" : "选择显示器 / 窗口", systemImage: "plus.rectangle.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }.controlSize(.large).disabled(capture.phase.isBusy)
                    Divider()
                    sectionTitle("存储格式", systemImage: "film")
                    Picker("编码", selection: $capture.codec) {
                        ForEach(MediaFormats.recordingCodecs) { Text($0.title).tag($0) }
                    }.disabled(capture.phase.isBusy)
                    Picker("容器", selection: $capture.container) {
                        ForEach(MediaFormats.recordingContainers(for: capture.codec)) { Text($0.title).tag($0) }
                    }.disabled(capture.phase.isBusy)
                    Picker("分辨率", selection: $capture.resolution) {
                        ForEach(CaptureResolution.allCases) { Text($0.title).tag($0) }
                    }.disabled(capture.phase.isBusy)
                    Text("30 fps · SDR · 显示鼠标指针").font(.caption).foregroundStyle(.secondary)
                    if !MediaFormats.canRecordDirectly(codec: capture.codec, container: capture.container) {
                        Text("停止后自动转换为所选格式；原始录屏也会保留。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if MediaFormats.exportCodecs.isEmpty {
                        Text("安装 FFmpeg 后可使用更多格式、转码和压缩。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Divider()
                    sectionTitle("声音", systemImage: "waveform")
                    Toggle("录制来源音频", isOn: $capture.sourceAudio).disabled(capture.phase.isBusy)
                    Toggle("录制麦克风", isOn: $capture.microphone).disabled(capture.phase.isBusy)
                    if capture.microphone {
                        Picker("设备", selection: $capture.microphoneID) {
                            Text("系统默认麦克风").tag("")
                            ForEach(capture.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                        }.disabled(capture.phase.isBusy)
                    }
                    Text("来源音频由 macOS 按共享范围提供；受保护内容可能无法录制。")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    sectionTitle("保存位置", systemImage: "folder")
                    Text(capture.directory.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3).textSelection(.enabled)
                    Button("更改目录…") { capture.chooseDirectory() }.disabled(capture.phase.isBusy)
                    Divider()
                    if capture.phase == .recording || capture.phase == .starting {
                        Button(role: .destructive) { Task { await capture.stop() } } label: {
                            Label("停止并保存", systemImage: "stop.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                    } else {
                        Button { Task { await capture.start() } } label: {
                            Label(capture.phase == .stopping ? "正在保存…" : "开始录制", systemImage: "record.circle")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                            .disabled(!capture.phase.canStart)
                    }
                    if capture.phase == .stopping || capture.phase == .preparing { ProgressView().controlSize(.small) }
                    Button("打开屏幕录制权限设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }.font(.caption).buttonStyle(.link)
                }
                .padding(20)
            }.frame(width: 300)
        }
        .onChange(of: capture.codec) { _, codec in
            if !MediaFormats.recordingContainers(for: codec).contains(capture.container) {
                capture.container = MediaFormats.recordingContainers(for: codec).first ?? .mp4
            }
        }
    }
}

private struct EditingView: View {
    @ObservedObject var editor: VideoEditor
    @State private var showCrop = true

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(editor.sourceURL?.lastPathComponent ?? "打开本地视频，编辑 / 转码 / 压缩", systemImage: "film")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("导入视频…") { Task { await editor.importVideo() } }
                        .disabled(editor.exporting || editor.loading)
                    Button("新建项目") { editor.newProject() }
                        .disabled(editor.exporting || editor.loading)
                }
                if !editor.sources.isEmpty {
                    Picker("原始视频", selection: Binding(get: { editor.currentSourceID }, set: { id in
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
                            Text("视频已载入，可裁剪或转码。当前格式不支持原生播放。")
                                .foregroundStyle(.white).padding()
                        }
                        if showCrop {
                            CropOverlay(size: editor.size, crop: $editor.crop)
                                .allowsHitTesting(!editor.exporting)
                        }
                    } else if editor.loading {
                        ProgressView("正在读取视频…").tint(.white).foregroundStyle(.white)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "crop.rotate").font(.system(size: 48, weight: .light))
                            Text("录制结束后在这里裁剪，或导入本地视频。")
                        }.foregroundStyle(.white.opacity(0.8))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                HStack {
                    Button { editor.previewSelection() } label: { Label("播放选中片段", systemImage: "play.fill") }
                        .disabled(!editor.nativePlayback)
                    Button { editor.player.pause() } label: { Image(systemName: "pause.fill") }
                    Spacer()
                    Toggle("显示裁剪框", isOn: $showCrop).toggleStyle(.checkbox)
                }.disabled(!editor.hasVideo || editor.exporting)
                if editor.hasVideo {
                    Text("原文件：\(Int(editor.size.width)) × \(Int(editor.size.height)) · \(ByteCountFormatter.string(fromByteCount: editor.sourceBytes, countStyle: .file))" +
                         (editor.nativePlayback ? "" : " · 当前格式使用静帧预览，调整起止时间可查看对应画面。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                GroupBox("当前片段 · 起止时间") {
                    VStack(spacing: 10) {
                        timeControl("开始", value: $editor.start)
                        timeControl("结束", value: $editor.end)
                        HStack {
                            Text("总时长 \(timeLabel(editor.duration))")
                            Spacer()
                            Text("当前 \(String(format: "%.2f", max(0, editor.end - editor.start))) 秒")
                        }.font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button { editor.addClip() } label: { Label("加入拼接列表", systemImage: "plus") }
                                .disabled(!editor.validDraft)
                            if editor.editedClipID != nil {
                                Button("更新所选片段") { editor.updateSelectedClip() }.disabled(!editor.validDraft)
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
                        sectionTitle("画面裁剪", systemImage: "crop")
                        Text("拖动四角裁剪，拖动选框移动。框外拖动可重新框选，也可输入各边裁去的像素。")
                            .font(.caption).foregroundStyle(.secondary)
                        marginControl("左", value: $editor.crop.left)
                        marginControl("上", value: $editor.crop.top)
                        marginControl("右", value: $editor.crop.right)
                        marginControl("下", value: $editor.crop.bottom)
                        Button("重置画面与时间") {
                            editor.crop = CropMargins()
                            editor.start = 0
                            editor.end = editor.duration
                        }.disabled(editor.exporting)
                        if editor.validEdit {
                            Text("输出 \(Int(editor.outputSize.width)) × \(Int(editor.outputSize.height)) 像素")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Divider()
                        sectionTitle("导出设置", systemImage: "square.and.arrow.up")
                        Picker("编码", selection: $editor.codec) {
                            ForEach(VideoCodec.allCases.filter { editor.availableFormats[$0] != nil }) { Text($0.title).tag($0) }
                        }.disabled(editor.exporting)
                        Picker("容器", selection: $editor.container) {
                            ForEach(editor.availableFormats[editor.codec] ?? []) { Text($0.title).tag($0) }
                        }.disabled(editor.exporting)
                        Picker("分辨率", selection: $editor.resolution) {
                            ForEach(CaptureResolution.allCases) { Text($0.title).tag($0) }
                        }.disabled(editor.exporting)
                        Picker("画质", selection: $editor.quality) {
                            ForEach(ExportQuality.allCases) { quality in
                                Text("\(quality.title) · 约 \(editor.sizeLabel(for: quality))").tag(quality)
                            }
                        }.disabled(editor.exporting)
                        Text("预计约 \(editor.sizeLabel(for: editor.quality)) · 视频 \(String(format: "%.0f", Double(editor.bitRate(for: editor.quality)) / 1000)) kb/s")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text("按目标码率和所选时长估算，实际大小随画面内容变化。高画质不保证小于原文件。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(editor.clips.isEmpty
                             ? "未添加片段时，导出当前画面的起止时间段；也可保持完整画面和时长直接转码。"
                             : "只导出拼接列表，按从上到下的顺序合成。输出尺寸由首段及分辨率设置决定，其余片段等比缩放，必要时补黑边。")
                            .font(.caption).foregroundStyle(.secondary)
                        if !editor.validEdit && editor.hasVideo {
                            Text("请检查裁剪范围和起止时间。")
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
                    Text("拼接列表 · \(editor.clips.count) 段 · 共 \(String(format: "%.2f", editor.clips.isEmpty ? 0 : editor.exportDuration)) 秒")
                        .font(.caption.bold())
                    Spacer()
                    if !editor.clips.isEmpty { Button("清空列表") { editor.clearClips() }.font(.caption) }
                }
                if editor.clips.isEmpty {
                    Text("导入一个或多个视频，选择时间段后点击“加入拼接列表”。同一视频可添加多段，允许重复及重叠。")
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
                                            Text(String(format: "%.2f → %.2f 秒 · %.2f 秒", clip.trim.start, clip.trim.end, clip.duration))
                                                .foregroundStyle(.secondary).monospacedDigit()
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain)
                                    Button { editor.moveClip(clip.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                                        .disabled(index == 0).help("向前移动")
                                    Button { editor.moveClip(clip.id, offset: 1) } label: { Image(systemName: "arrow.down") }
                                        .disabled(index == editor.clips.count - 1).help("向后移动")
                                    Button { editor.removeClip(clip.id) } label: { Image(systemName: "minus.circle") }
                                        .help("移除片段")
                                }.font(.caption).padding(6)
                                    .background(editor.editedClipID == clip.id ? Color.accentColor.opacity(0.12) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }.frame(height: min(130, CGFloat(editor.clips.count) * 48))
                    Text("点击片段可修改，修改后点“更新所选片段”；列表顺序就是导出顺序。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }.disabled(editor.exporting || editor.loading)
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editor.exporting {
                ProgressView(value: Double(editor.progress))
                Text("正在导出 \(Int(editor.progress * 100))%")
                    .font(.caption.monospacedDigit())
                Button("取消导出", role: .destructive) { editor.cancelExport() }
            } else {
                Button {
                    guard let url = editor.savePanel() else { return }
                    Task { await editor.export(to: url) }
                } label: {
                    Label(editor.clips.isEmpty ? "导出当前片段…" : "导出拼接视频…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!editor.validEdit || editor.availableFormats.isEmpty)
            }
            if let url = editor.exportedURL {
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    private func timeControl(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 30)
            Slider(value: value, in: 0...max(0.01, editor.duration)) { editing in
                if !editing { editor.seek(value.wrappedValue) }
            }
            TextField("秒", value: value, format: .number.precision(.fractionLength(2)))
                .frame(width: 80).textFieldStyle(.roundedBorder)
                .onSubmit { editor.seek(value.wrappedValue) }
            Text("秒").foregroundStyle(.secondary)
        }
    }

    private func marginControl(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("像素", value: value, format: .number.precision(.fractionLength(0)))
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
