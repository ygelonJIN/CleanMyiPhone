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

                // 压缩站：照片页点「压缩」只是标记，真压缩在站里二次确认
                Label("压缩站", systemImage: "arrow.down.right.and.arrow.up.left")
                    .countBadge(store.compression.count)
                    .tag(AppStore.SidebarItem.compression)
                    .help("标记待压缩的照片都在这儿；这里点「开始压缩」才真的动设备（整批只写一次相册库）")

                // 修改站：收藏 / 移动相簿 / 新建相簿都先攒着，到这儿一次写回
                Label("修改站", systemImage: "square.and.pencil")
                    .countBadge(store.edits.badgeCount)
                    .tag(AppStore.SidebarItem.edits)
                    .help("收藏、移动相簿、新建相簿都只是暂存；这儿点「写回手机」才真的改 iPhone（整批只写一次相册库）")
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

    /// 左下角：**读取中也一直显示**。
    /// 以前是 `if !store.isScanning { purgeButton }` —— 点顶栏刷新时这块整个消失，
    /// 扫完又冒回来，用户看到的就是"清空按钮不见了，可它也没刷新"。
    /// 现在只把按钮置灰、上面加一行"正在读取"，位置不动。
    private var cacheBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            purgeButton
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
            if store.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(store.scanStageTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text("退出即清空 · 本机不留缓存")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("⌘Q、关窗口、崩溃、强制退出，都不会在这台电脑上留下照片数据。唯一留下的是压缩参数（比例/格式/质量三个数，不含任何照片信息），下次打开还是上次设的那一套")

            HStack(spacing: 6) {
                Button("清空本机数据", systemImage: "trash.slash") {
                    store.purgeLocalData()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.isScanning)
                .help("立刻删掉缩略图、临时原图/原视频、相册库中转文件；清完不会自动重建")

                Button("重新读取", systemImage: "arrow.clockwise") {
                    store.resumeReading()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                // 正常状态下也**永远可点**（2026-11 用户定的）：以前只在暂停态可点，
                // 没清空过就等于摆着看。清空过时 resumeReading 顺手解除暂停，没清空时就是重读一遍。
                .disabled(store.isScanning)
                .help("重新读取设备（重扫照片目录 + 重读相册索引）")
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
