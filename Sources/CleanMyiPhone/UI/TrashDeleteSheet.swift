import SwiftUI

/// 全流程只剩这一处二次确认：**回收站里的彻底删除**（真的动设备）。
///
/// 打标记不弹窗 —— 回收站本身就是那道保险，两层够了；
/// 再叠一层「确定标记？」等于点三次才动到一张照片。
struct EmptyTrashSheet: View {
    @Environment(AppStore.self) private var store
    /// 弹窗内容自己再走一遍 spring：系统 sheet 只负责滑下来的壳子，
    /// 内容"啪"地出现会显得很毛躁
    @State private var appeared = false

    /// 要删的那一批：`pendingDeleteIDs` 空 = 全部
    private var entries: [TrashStore.Entry] {
        store.pendingDeleteIDs.isEmpty
            ? store.trash.entries
            : store.trash.entries.filter { store.pendingDeleteIDs.contains($0.id) }
    }

    private var totalBytes: Int64 { entries.reduce(0) { $0 + $1.byteSize } }

    private var wallItems: [TrashStore.Entry] { Array(entries.prefix(12)) }
    private var rows: [[TrashStore.Entry]] {
        stride(from: 0, to: wallItems.count, by: 6).map {
            Array(wallItems[$0..<min($0 + 6, wallItems.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("彻底删除 \(entries.count) 项？")
                    .font(.system(size: 15, weight: .semibold))
                Text("会从 iPhone 上真正删掉，释放 \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))，删完无法恢复。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            wall

            // 苹果原生顺序：取消在左、危险动作在右，取消吃 Esc
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("取消") {
                    store.emptyTrashConfirmPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)

                Button(role: .destructive) {
                    let ids = store.pendingDeleteIDs
                    store.emptyTrashConfirmPresented = false
                    store.pendingDeleteIDs = []
                    Task {
                        if ids.isEmpty {
                            await store.emptyTrash()
                        } else {
                            await store.deleteFromTrash(ids: ids)
                        }
                    }
                } label: {
                    Text("彻底删除")
                        .frame(minWidth: 68)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(.background)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.96)
        .onAppear {
            withAnimation(Motion.sheet) { appeared = true }
        }
    }

    /// 缩略图墙：每行最多 6 张、整行居中；数量少的时候不会一边倒，
    /// 多的时候固定 12 张 + 一个「+N」，高度不会把弹窗撑爆。
    private var wall: some View {
        VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row) { entry in
                        thumb(entry)
                    }
                    // 最后一行末尾补一个「还有 N 项」
                    if row.last?.id == wallItems.last?.id, entries.count > wallItems.count {
                        Text("+\(entries.count - wallItems.count)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 56, height: 56)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.secondary.opacity(0.12))
                            )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 120, maxHeight: 190, alignment: .center)
        .padding(.vertical, 2)
    }

    private func thumb(_ entry: TrashStore.Entry) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
            if let image = store.thumbnails[entry.id] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: entry.isVideo ? "video" : "photo")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(entry.fileName)
    }
}
