import AppKit
import SwiftUI

/// 照片页：左边一列相簿（相簿再多也只在自己这条列表里滚），右边缩略图 / 列表。
struct PhotosView: View {
    @Environment(AppStore.self) private var store
    @State private var showAlbums = true

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            DetailHeader(title: store.currentScopeTitle, subtitle: nil, showTitle: false) {
                HStack(spacing: 10) {
                    if !store.libraryAlbums.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { showAlbums.toggle() }
                        } label: {
                            Image(systemName: showAlbums ? "sidebar.left" : "sidebar.leading")
                        }
                        .buttonStyle(.borderless)
                        .help(showAlbums ? "隐藏相簿栏" : "显示相簿栏")
                    }

                    SearchField(prompt: "搜索照片", text: $store.searchText, width: 112)

                    // 主打功能：排序与视图都放大、放显眼
                    HStack(spacing: 6) {
                        Picker("排序", selection: $store.sortKey) {
                            ForEach(SortKey.allCases) { key in
                                Text(key.label).tag(key)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 150)
                        .help("排序方式：按时间 / 按大小 / 按文件名")

                        Button {
                            store.ascending.toggle()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: store.ascending ? "arrow.up" : "arrow.down")
                                    .font(.system(size: 10, weight: .bold))
                                Text(store.ascending ? "升序" : "降序")
                                    .font(.caption.weight(.medium))
                            }
                            .frame(width: 58)
                        }
                        .buttonStyle(.bordered)
                        .help("点一下切换升序 / 降序")
                    }

                    if store.showsDateSections {
                        Picker("分组", selection: $store.dateGrouping) {
                            ForEach(AppStore.DateGrouping.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 104)
                        .help("按日 / 按月 / 按年分组显示")
                    }

                    Picker("视图", selection: $store.viewMode) {
                        ForEach(ViewMode.allCases) { mode in
                            Image(systemName: mode.symbol).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 84)
                    .help("缩略图视图 / 列表视图")

                    Button {
                        Task { await store.startScan() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("重新读取设备")
                    .disabled(store.isScanning)
                }
            }

            Divider()
                .padding(.top, 4)

            HStack(spacing: 0) {
                if showAlbums, !store.libraryAlbums.isEmpty {
                    AlbumRail()
                        .frame(width: 190)
                    Divider()
                }
                content
            }

            Divider()
            bottomBar
        }
        // 换排序 / 换升降序 / 换相簿：让所有格子重新走一遍取图流程。
        // 光靠 ForEach 复用不会重发 `.task(id:)`，而且上一屏排队的请求要立刻作废。
        .onChange(of: store.sortKey) { _, _ in store.bumpThumbEpoch() }
        .onChange(of: store.ascending) { _, _ in store.bumpThumbEpoch() }
        .onChange(of: store.sidebarItem) { _, _ in store.bumpThumbEpoch() }
        // 相册库还没读完：整页盖一层进度，读完自动撤。
        // 这段时间预览也开不了（没有库就拿不到设备上的真实路径）。
        .overlay {
            // 库索引没读完的普通情况已经由根视图那层全屏遮罩接走（`needsLibraryGate`）；
            // 这里只留**暂停态**：「本机数据已清空」要让用户看得到，并且左下角
            // 「重新读取」必须点得动，所以不能走那层盖死的遮罩。
            if store.dataPaused {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                libraryGate
            }
        }
    }

    /// 库索引读取中的硬提示：和预览卡片同一套样式
    private var libraryGate: some View {
        VStack(spacing: 10) {
            if store.dataPaused {
                Image(systemName: "trash.slash")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.large)
            }
            VStack(spacing: 2) {
                Text(store.dataPaused ? "本机数据已清空" : "正在读取相册索引")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                if store.libraryBytesTotal > 0 {
                    Text("\(AppStore.sizeText(store.libraryBytesDone)) / \(AppStore.sizeText(store.libraryBytesTotal))")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 300)
                }
            }
            if store.libraryBytesTotal > 0, !store.dataPaused {
                ProgressView(value: min(1, Double(store.libraryBytesDone) / Double(max(store.libraryBytesTotal, 1))))
                    .progressViewStyle(.linear)
                    .frame(width: 300)
            }
            Text(store.dataPaused ? "点左下角「重新读取」重新建立" : "读完就能浏览与预览（约 8 秒）")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var subtitle: String {
        if store.isScanning {
            return "\(store.visibleAssets.count) 项 · \(store.scanStageTitle)"
        }
        return "\(store.visibleAssets.count) 项 · \(AppStore.sizeText(store.visibleBytes))"
    }

    // MARK: - 工具栏

    /// 排序做成看得见的状态：按钮上直接写「时间 ↓」，不是一个小箭头
    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if store.needsConnection {
            EmptyStateView(icon: "iphone.slash",
                           title: "没有检测到 iPhone",
                           message: "用数据线把手机连上，解锁后点「信任」，再回来刷新。",
                           actionTitle: "重新检测") {
                store.connectRealDevice()
            }
        } else if store.visibleAssets.isEmpty && store.isScanning {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.visibleAssets.isEmpty {
            EmptyStateView(icon: "photo.on.rectangle.angled",
                           title: "这里还没有内容",
                           message: store.assets.isEmpty
                                ? "还没读到照片。插上数据线，在 iPhone 上点「信任」。"
                                : "这个相簿或筛选条件下没有项，换一个看看。",
                           actionTitle: store.assets.isEmpty ? "重新读取" : "查看全部") {
                if store.assets.isEmpty {
                    Task { await store.startScan() }
                } else {
                    store.select(.photos(.all))
                    store.clearFilters()
                    store.searchText = ""
                }
            }
        } else {
            switch store.viewMode {
            case .grid: PhotoGrid()
            case .list: PhotoList()
            }
        }
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text("\(store.visibleAssets.count) 项 · \(AppStore.sizeText(store.visibleBytes))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if store.trash.count > 0 {
                Button {
                    store.select(.trash)
                } label: {
                    Label("待释放 \(AppStore.sizeText(store.trash.totalBytes))",
                          systemImage: "trash")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if store.selection.isEmpty {
                Text("⌘ 点加选 · ⇧ 点连选 · 空格看大图 · S 在预览里选中")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("已选 \(store.selection.count) 项 · \(AppStore.sizeText(store.selectedBytes))")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()

                Button("删除…") { store.presentDeleteConfirm() }
                Button("取消选择") { store.clearSelection() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// 相簿栏：搬出侧栏之后，相簿再多也只在这里滚
struct AlbumRail: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                row(title: "全部照片",
                    count: store.assets.count,
                    bytes: store.totalBytes,
                    symbol: "photo.on.rectangle.angled",
                    selected: store.albumFilter == nil && store.libraryFilter == .all) {
                    store.select(.photos(.all))
                }

                Divider()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)

                Text("相簿")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 3)

                ForEach(store.libraryAlbums) { album in
                    row(title: album.title,
                        count: album.count,
                        bytes: store.albumBytes(album.id),
                        symbol: "rectangle.stack",
                        selected: store.albumFilter == album.id) {
                        store.select(.album(album.id))
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background.secondary.opacity(0.4))
    }

    private func row(title: String,
                     count: Int,
                     bytes: Int64,
                     symbol: String,
                     selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.white : .secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(count) 张")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                    Text(AppStore.sizeText(bytes))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor : .clear)
            )
            .foregroundStyle(selected ? Color.white : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }
}
