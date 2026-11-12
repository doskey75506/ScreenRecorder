import AppKit
import SwiftUI
import RecorderCore

@main
struct ScreenRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var capture = CaptureService()
    @StateObject private var editor = VideoEditor()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("ScreenRecorder · 录屏", id: "main") {
            MainView(capture: capture, editor: editor)
                .onAppear {
                    delegate.capture = capture
                    delegate.editor = editor
                }
        }
        .defaultSize(width: 1080, height: 790)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            Button("显示主窗口") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Text(capture.phase.title + (capture.phase == .recording ? " · " + timeLabel(capture.elapsed) : ""))
            if capture.phase == .recording || capture.phase == .starting {
                Button("停止录制并保存") { Task { await capture.stop() } }
            }
            Divider()
            Button("退出 ScreenRecorder") { NSApp.terminate(nil) }
        } label: {
            Label("录屏", systemImage: capture.phase == .recording ? "record.circle.fill" : "record.circle")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var capture: CaptureService?
    weak var editor: VideoEditor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { editor?.closeSession() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let capture, let editor else { return .terminateNow }
        guard capture.phase.isBusy || editor.exporting || editor.loading else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "退出 ScreenRecorder？"
        alert.informativeText = "正在进行的录制将停止并尝试保存，未完成的导出将取消。"
        alert.addButton(withTitle: "停止并退出")
        alert.addButton(withTitle: "继续使用")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            editor.cancelExport()
            await capture.stop()
            for _ in 0..<200 {
                if capture.phase != .stopping && !editor.exporting && !editor.loading { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
