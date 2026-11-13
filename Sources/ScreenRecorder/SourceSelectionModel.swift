import Foundation
import Combine
import RecorderCore

struct CaptureSourceOption: Identifiable, Equatable, Sendable {
    let id: UInt32
    let title: String
    let detail: String
    let ownerProcessID: Int32?

    init(id: UInt32, title: String, detail: String = "", ownerProcessID: Int32? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.ownerProcessID = ownerProcessID
    }

    func hasSameIdentity(as other: CaptureSourceOption) -> Bool {
        id == other.id && ownerProcessID == other.ownerProcessID
    }
}

enum SourceSelectionError: BilingualLocalizedError {
    case permissionRequired, unavailable

    var localizedMessage: LocalizedMessage {
        switch self {
        case .permissionRequired:
            LocalizedMessage("Screen Recording access is unavailable. Use the macOS picker or enable access in System Settings.",
                             "屏幕录制权限不可用。请使用系统选源器，或在系统设置中允许访问。")
        case .unavailable:
            LocalizedMessage("This source is no longer available. Refresh the list and select another source.",
                             "所选来源已不可用。请刷新列表并重新选择。")
        }
    }
}

@MainActor
final class SourceSelectionModel: ObservableObject, Identifiable {
    let id = UUID()
    let mode: RecordingSource
    @Published private(set) var options: [CaptureSourceOption] = []
    @Published private(set) var loading = false
    @Published var confirming = false
    @Published var selectedID: UInt32?
    @Published var error: LocalizedMessage?
    private let load: () async throws -> [CaptureSourceOption]
    private var generation = UUID()

    init(mode: RecordingSource, load: @escaping () async throws -> [CaptureSourceOption]) {
        self.mode = mode
        self.load = load
    }

    var selectedOption: CaptureSourceOption? { options.first { $0.id == selectedID } }
    var canConfirm: Bool { !loading && !confirming && selectedOption != nil }

    func refresh() async {
        guard !confirming else { return }
        let request = UUID()
        generation = request
        let previous = selectedOption
        loading = true
        error = nil
        defer { if generation == request { loading = false } }
        do {
            let updated = try await load()
            guard generation == request, !Task.isCancelled else { return }
            options = updated
            // Never silently select another source when a window disappears or
            // its ID is reused by a different process.
            if let previous, !updated.contains(where: { $0.hasSameIdentity(as: previous) }) { selectedID = nil }
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            self.error = LocalizedMessage(error: error)
        }
    }

    func cancel() {
        generation = UUID()
        loading = false
    }
}
