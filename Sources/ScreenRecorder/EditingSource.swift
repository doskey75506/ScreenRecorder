import Foundation
import RecorderCore
import Darwin

enum EditingSourceError: BilingualLocalizedError {
    case unavailable(String)
    var localizedMessage: LocalizedMessage {
        switch self {
        case .unavailable(let name): LocalizedMessage("Cannot find or read the source video “\(name)”. Select it again. Existing clips and crop settings have been kept.", "找不到或无法读取源视频“\(name)”。请重新选择文件；已有片段与裁剪参数保持不变。")
        }
    }
}

/// An independent session snapshot: repeated exports never depend on the original pathname.
/// APFS clones share storage until changed; other filesystems fall back to a normal copy.
final class EditingSource: @unchecked Sendable {
    let originalURL: URL
    let workingURL: URL
    private let directory: URL

    init(url: URL) throws {
        originalURL = url
        let original = url.resolvingSymlinksInPath()
        guard FileManager.default.isReadableFile(atPath: original.path) else {
            throw EditingSourceError.unavailable(url.lastPathComponent)
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenRecorder-edit-" + UUID().uuidString)
        workingURL = directory.appendingPathComponent("source").appendingPathExtension(url.pathExtension.isEmpty ? "mp4" : url.pathExtension)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let result = original.path.withCString { source in
                workingURL.path.withCString { destination in clonefile(source, destination, 0) }
            }
            if result != 0 { try FileManager.default.copyItem(at: original, to: workingURL) }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func discard() { try? FileManager.default.removeItem(at: directory) }
    deinit { discard() }
}
