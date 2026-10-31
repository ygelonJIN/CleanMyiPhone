import SwiftUI

/// 原生 macOS 侧边栏：固定五项 + Section 分组 + 统一选中项。
/// 相簿不再挂在这里（搬进照片页的二级导航列），所以这一栏永远不会被挤爆。
struct MainSidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var hoveringCacheButton = false

    private var selection: Binding<AppStore.SidebarItem?> {
        Binding(
            get: {
                // 相簿在照片页自己的栏里选，侧栏这一行就落在「全部照片」上，
                // 否则会出现「侧栏全空、内容却在显示某个相簿」的错位。
                if case .album = store.sidebarItem { return .photos(.all) }
                return store.sidebarItem
            },
            set: { if let item = $0 { store.select(item) } }
        )
    }

    /// 每一行都显示「数量 · 体积」，不只是已隐藏那几项
    private func detailText(for filter: LibraryFilter) -> String? {
        let count = store.count(for: filter)
        let bytes = store.sizeForFilter(filter)
        guard count > 0 || bytes > 0 else { return nil }
        return "\(count) · \(AppStore.sizeText(bytes))"
    }

    var body: some View {
        VStack(spacing: 0) {
            list
        }
        .background(.regularMaterial)
    }

    private var list: some View {
        List(selection: selection) {
            Section {
                Label("概览", systemImage: "gauge.with.dots.needle.33percent")
                    .tag(AppStore.SidebarItem.overview)
            }

            Section("照片") {
                ForEach(LibraryFilter.displayOrder) { filter in
                    HStack(spacing: 8) {
                        Label(filter.title, systemImage: filter.symbol)
                        Spacer(minLength: 6)
                        if let detail = detailText(for: filter) {
                            Text(detail)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .tag(AppStore.SidebarItem.photos(filter))
                }
            }

            Section("设备") {
                Label("回收站", systemImage: "trash")
                    .countBadge(store.trash.count)
                    .tag(AppStore.SidebarItem.trash)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { cacheBar }
    }

    /// 左下角：一个按钮（不是底栏）
    private var cacheBar: some View {
        HStack {
            Button {
                store.clearThumbnailCache()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                    Text("清除缩略图缓存")
                        .font(.caption)
                    if store.thumbnailCacheBytes > 0 {
                        Text(AppStore.sizeText(store.thumbnailCacheBytes))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(hoveringCacheButton ? 0.16 : 0.08))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringCacheButton = $0 }
            .help("删掉本地缓存的缩略图，缩略图会自动重新生成")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}
