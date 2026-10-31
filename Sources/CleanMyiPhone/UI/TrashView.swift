import SwiftUI

struct TrashView: View {
    @Environment(AppStore.self) private var store
    @State private var confirmEmpty = false

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: "回收站", subtitle: "\(store.trash.count) 项 · \(ByteCountFormatter.string(fromByteCount: store.trash.totalBytes, countStyle: .file))") {
                HStack(spacing: 8) {
                    Button("全部放回去") {
                        store.restoreFromTrash(ids: store.trash.entries.map(\.id))
                    }
                    .disabled(store.trash.entries.isEmpty || store.isPurging)

                    Button("清空回收站") { confirmEmpty = true }
                        .disabled(store.trash.entries.isEmpty || store.isPurging)
                }
            }
            if let message = store.purgeMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
            }
            Divider()
            if store.trash.entries.isEmpty {
                EmptyStateView(icon: "trash",
                               title: "回收站是空的",
                               message: "在照片页勾选后点「删除」，东西会先到这里。放回去是瞬时的，清空才真正从 iPhone 上删除。")
            } else {
                list
            }
        }
        .alert("清空回收站？", isPresented: $confirmEmpty) {
            Button("取消", role: .cancel) {}
            Button("清空并删除", role: .destructive) {
                Task { await store.emptyTrash() }
            }
        } message: {
            Text("这会从 iPhone 上真正删除 \(store.trash.count) 项，释放 \(ByteCountFormatter.string(fromByteCount: store.trash.totalBytes, countStyle: .file))，删除后无法恢复。")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.trash.entries) { entry in
                    row(entry)
                    Divider()
                }
            }
        }
    }

    private func row(_ entry: TrashStore.Entry) -> some View {
        let asset = store.assets.first { $0.id == entry.id }
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if let asset, let image = store.thumbnails[asset.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: entry.isVideo ? "video" : "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileName).font(.callout).lineLimit(1)
                Text("\(entry.createdAt.formatted(.dateTime.year().month().day().hour().minute())) · \(entry.folder)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: entry.byteSize, countStyle: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button("放回去") { store.restoreFromTrash(ids: [entry.id]) }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }
}
