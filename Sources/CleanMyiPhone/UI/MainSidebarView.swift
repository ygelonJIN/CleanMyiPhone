import SwiftUI

/// 原生 macOS 侧边栏：固定五项 + Section 分组 + 统一选中项。
/// 相簿不再挂在这里（搬进照片页的二级导航列），所以这一栏永远不会被挤爆。
struct MainSidebarView: View {
    @Environment(AppStore.self) private var store

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

    /// 每一行都显示「数量 · 体积」。
    /// 三种状态各有固定文案，宽度也预留好，数字到了不会把行撑跳：
    /// 有数 → `1234 · 4.2 GB`；还在算 → `加载中…`；库读不到 → `—`
    @ViewBuilder
    private func metric(for filter: LibraryFilter) -> some View {
        if let value = store.filterMetrics[filter] {
            Text("\(value.count) · \(AppStore.sizeText(value.bytes))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else if store.metricsLibraryUnavailable {
            Text("—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.quaternary)
        } else {
            LoadingText()
        }
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
                        metric(for: filter)
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

    /// 左下角：只在「概览」页显示。
    /// 别的页面（尤其全屏预览、锁屏提示）不该出现这个勾选框。
    private var cacheBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 读取过程中（全屏「正在读取…」那一屏）整块都不出现，
            // 读完了在概览 / 照片 / 回收站任何页面都显示，勾选框和文字一起进一起出。
            if !store.isScanning {
                purgeButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    /// 底部三件：自动清空勾选 + 立刻清空 + 重新读取
    private var purgeButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { store.autoPurge },
                                 set: { store.setAutoPurge($0) })) {
                Text("自动清空本机数据")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .help("勾上：退出 App 和下次启动时自动删干净")

            HStack(spacing: 6) {
                Button("清空本机数据", systemImage: "trash.slash") {
                    store.purgeLocalData()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("立刻删掉缩略图缓存、相册库快照和所有临时原图/原视频副本；清完不会自动重建")

                Button("重新读取", systemImage: "arrow.clockwise") {
                    store.resumeReading()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!store.dataPaused)
                .help("清空之后用它重新读取设备、重建缩略图")
            }

            if store.purgeLeftovers.isEmpty, let message = store.purgeMessage {
                Text(message)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !store.purgeLeftovers.isEmpty {
                Text("有 \(store.purgeLeftovers.count) 项没删掉：\(store.purgeLeftovers.joined(separator: "、"))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}
