import SwiftUI

/// 两层确认：第一层看清单，第二层只看一句话和一个按钮。
struct ConfirmSheet: View {
    @Environment(AppStore.self) private var store

    private var chosen: [Asset] { store.selectedAssets }

    var body: some View {
        VStack(spacing: 0) {
            if store.confirmStage == 1 { stageOne } else { stageTwo }
        }
        .frame(width: 580)
        .background(.background)
    }

    // MARK: - 第一层

    private var stageOne: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("删除这 \(chosen.count) 项？")
                .font(.title3.weight(.semibold))

            Text("共 \(ByteCountFormatter.string(fromByteCount: store.selectedBytes, countStyle: .file))。删掉之后会先进入回收站，清空回收站才真正腾出空间。")
                .font(.callout)
                .foregroundStyle(.secondary)

            wall

            HStack {
                Text("来自 \(albumHint)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("取消") { store.confirmPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("删除") { store.confirmStage = 2 }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private var wall: some View {
        let preview = Array(chosen.prefix(12))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
            ForEach(preview) { asset in
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    if let image = store.thumbnails[asset.id] {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: asset.kind.symbol).foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxHeight: 190)
    }

    private var albumHint: String {
        let folders = Set(chosen.map(\.folder))
        return folders.count == 1 ? (folders.first ?? "相机胶卷") : "\(folders.count) 个相簿"
    }

    // MARK: - 第二层

    private var stageTwo: some View {
        VStack(spacing: 18) {
            Image(systemName: "trash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.orange)

            Text("\(chosen.count) 项 · \(ByteCountFormatter.string(fromByteCount: store.selectedBytes, countStyle: .file))")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()

            Text("确定删除？删掉之后会进入回收站，清空回收站才真正从 iPhone 上删除。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack {
                Button("返回") { store.confirmStage = 1 }
                    .keyboardShortcut(.cancelAction)
                Button("确定删除 \(chosen.count) 项") { store.confirmDelete() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
    }
}
