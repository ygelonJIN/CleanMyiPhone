import SwiftUI

/// 原生 macOS 侧边栏：概览 + 照片（全部照片 / 相簿 / 各类型）+ 回收站。
/// 相簿现在自己占一行（点进去是相簿墙），不再挤在照片页里，所以这一栏永远不会被挤爆。
struct MainSidebarView: View {
    @Environment(AppStore.self) private var store

    private var selection: Binding<AppStore.SidebarItem?> {
        Binding(
            get: {
                // 「某个相簿里」和「相簿墙」都落在「相簿」这一行上，
                // 否则会出现「侧栏高亮在全部照片、内容却是某个相簿」的错位。
                switch store.sidebarItem {
                case .album, .albums: return .albums
                default: return store.sidebarItem
                }
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
                    .help(filter.help)
                    .tag(AppStore.SidebarItem.photos(filter))

                    // 相簿紧跟在「全部照片」下面（位置是用户定的）
                    if filter == .all {
                        albumRow
                    }
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

    /// 「相簿」这一行：右边只报相簿个数，不报张数体积（那会和「全部照片」重复）
    private var albumRow: some View {
        HStack(spacing: 8) {
            Label("相簿", systemImage: "rectangle.stack")
            Spacer(minLength: 6)
            if store.libraryAlbums.isEmpty {
                if store.metricsLibraryUnavailable {
                    Text("—")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.quaternary)
                } else {
                    LoadingText()
                }
            } else {
                Text("\(store.libraryAlbums.count) 个")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .help("点开看全部相簿，再点某个相簿进去看里面的照片和视频")
        .tag(AppStore.SidebarItem.albums)
    }

    /// 左下角：读取结束后才出现。别的页面（全屏预览、锁屏提示）不该出现这两个按钮。
    private var cacheBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !store.isScanning {
                purgeButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    /// 底部两件：立刻清空 + 重新读取。
    /// 没有「自动清空」开关了：退出即清空是无条件的 —— 开关本身就是一条痕迹，
    /// 而且关掉它等于允许硬盘上留一份 296 MB 的照片库复印件。
    private var purgeButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("退出即清空 · 本机不留缓存")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("⌘Q、关窗口、崩溃、强制退出，都不会在这台电脑上留下照片数据")

            HStack(spacing: 6) {
                Button("清空本机数据", systemImage: "trash.slash") {
                    store.purgeLocalData()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("立刻删掉缩略图、临时原图/原视频、相册库中转文件；清完不会自动重建")

                Button("重新读取", systemImage: "arrow.clockwise") {
                    store.resumeReading()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!store.dataPaused)
                .help("清空之后用它重新读一遍设备")
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
