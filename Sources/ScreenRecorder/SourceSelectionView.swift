import SwiftUI
import RecorderCore

struct SourceSelectionView: View {
    @ObservedObject var model: SourceSelectionModel
    let confirm: () -> Void
    let cancel: () -> Void
    let useSystemPicker: () -> Void
    @State private var search = ""

    private var visibleOptions: [CaptureSourceOption] {
        model.options.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) ||
            $0.detail.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.mode == .window ? L10n.text("Choose a window", "选择窗口") : L10n.text("Choose a screen", "选择屏幕"))
                .font(.title2.bold())
            Text(L10n.text("Select a source to preview. Manage Screen Recording access in System Settings.",
                           "选择来源即可预览；可在系统设置中管理屏幕录制权限。"))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField(L10n.text("Search sources", "搜索来源"), text: $search)
                    .textFieldStyle(.roundedBorder).disabled(model.confirming)
                Button(L10n.text("Refresh", "刷新")) { Task { await model.refresh() } }
                    .disabled(model.loading || model.confirming)
            }
            ZStack {
                List(selection: $model.selectedID) {
                    ForEach(visibleOptions) { option in
                        HStack(spacing: 12) {
                            Image(systemName: model.mode.systemImage).font(.title2).frame(width: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.title).lineLimit(1).truncationMode(.middle)
                                Text(option.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.vertical, 5).tag(option.id)
                    }
                }.disabled(model.loading || model.confirming)
                if model.loading {
                    ProgressView(L10n.text("Loading sources…", "正在读取来源…"))
                        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                } else if visibleOptions.isEmpty {
                    Text(search.isEmpty ? L10n.text("No sources found. Refresh or use the macOS picker.", "未找到来源，请刷新或使用系统选源器。")
                         : L10n.text("No matching sources", "没有匹配的来源"))
                        .foregroundStyle(.secondary).padding().allowsHitTesting(false)
                }
            }.frame(minHeight: 160, maxHeight: .infinity)
            if let error = model.error {
                Text(error.text()).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .lineLimit(3).help(error.text())
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10n.text("Use macOS picker…", "使用系统选源器…"), action: useSystemPicker)
                    .disabled(model.confirming)
                Spacer()
                Button(L10n.text("Cancel", "取消"), action: cancel).keyboardShortcut(.cancelAction)
                Button(L10n.text("Preview source", "预览所选来源"), action: confirm)
                    .keyboardShortcut(.defaultAction).disabled(!model.canConfirm)
            }
        }.padding(22).frame(width: 560, height: 450)
            .task { await model.refresh() }
            .onChange(of: search) { _, _ in
                if !visibleOptions.contains(where: { $0.id == model.selectedID }) { model.selectedID = nil }
            }
            .onDisappear { model.cancel() }
    }
}
