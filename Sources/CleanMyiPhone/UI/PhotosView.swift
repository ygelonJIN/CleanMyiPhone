import AppKit
import SwiftUI

/// 照片页：一页只显示一个范围（全部照片 / 某个类型 / 某个相簿）的缩略图或列表。
/// 相簿不再挂在这一页的左边 —— 它自己是一页（`AlbumsView`），这里只放「返回相簿」。
struct PhotosView: View {
    @Environment(AppStore.self) private var store
    @State private var showConversion = false

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            // 顶栏没有标题，控件组整条居中；每个控件都收窄过（升降序改成文字），
            // 合计 ≤ 452pt，配内容区最小宽 500 任何窗口尺寸都不裁。
            // 那层横向 ScrollView 已经删掉：宽度本来就够，兜底那层反而是裁刷新按钮的元凶。
            PageToolbar {
                SearchField(prompt: "搜索照片", text: $store.searchText, width: 100)

                // 主打功能：排序与视图都放大、放显眼
                Picker("排序", selection: $store.sortKey) {
                    ForEach(SortKey.allCases) { key in
                        Text(key.label).tag(key)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 100)
                .help("排序方式：按时间 / 按大小")

                // 升 / 降序用**文字**，不用箭头（用户定的）
                Button {
                    store.ascending.toggle()
                } label: {
                    Text(store.ascending ? "升序" : "降序")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(width: 44, height: 20)
                }
                .buttonStyle(.bordered)
                .help(store.ascending ? "当前升序 · 点一下改为降序" : "当前降序 · 点一下改为升序")

                if store.showsDateSections {
                    Picker("分组", selection: $store.dateGrouping) {
                        ForEach(AppStore.DateGrouping.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 84)
                    .help("按日 / 按月 / 按年分组显示")
                }

                Picker("视图", selection: $store.viewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Image(systemName: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 68)
                .help("缩略图视图 / 列表视图")

                refreshButton
            }

            Divider()

            HStack(spacing: 0) {
                if store.section == .albums {
                    AlbumRail()
                        .frame(minWidth: 190, idealWidth: 190, maxWidth: 190)
                    Divider()
                }
                content
                    // 最小宽度只保证「两列」：再窄宁可窗口不放行，也不裁图
                    .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                    // 换页（侧栏 / 相簿 / 视图）时整块淡入 + 微缩，不是"啪"地出现
                    .pageReveal(store.pageKey)
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
        .sheet(isPresented: $showConversion) {
            ConversionSheet()
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
            // `errorText` 以前是**只写不读**的死状态：读不到目录/会话断了，
            // 界面只给一句「还没读到照片。插上数据线…」——等于什么都不说。
            // 现在把真正的原因放在这里（读失败、刷新超时、会话断开都在这里露面）。
            EmptyStateView(icon: "photo.on.rectangle.angled",
                           title: store.assets.isEmpty && store.errorText != nil
                                ? "没读到照片" : "这里还没有内容",
                           message: store.assets.isEmpty
                                ? (store.errorText
                                   ?? "还没读到照片。插上数据线，在 iPhone 上点「信任」。")
                                : "这个相簿或筛选条件下没有项，换一个看看。",
                           actionTitle: store.assets.isEmpty ? "重新读取" : "查看全部") {
                if store.assets.isEmpty {
                    Task { await store.refreshDevice() }
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

    /// 刷新：真的重读设备（目录 + 相册索引）。读取中换成小转圈，别让人连点。
    @ViewBuilder
    private var refreshButton: some View {
        Button {
            Task { await store.refreshDevice() }
        } label: {
            if store.isScanning {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16, height: 16)
            }
        }
        .buttonStyle(.borderless)
        // 右侧多留一点：这一颗最靠边，最容易被裁掉/被滚动条压住
        .frame(minWidth: 22, minHeight: 20)
        .contentShape(Rectangle())
        .help(store.isScanning ? "正在重新读取设备…" : "重新读取设备（重扫照片目录 + 重读相册索引，约 10 秒）")
        .disabled(store.isScanning)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text("\(store.visibleAssets.count) 项 · \(AppStore.sizeText(store.visibleBytes))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            // 两个标记分开报：标记回收、标记压缩是两件事。
            // **只报这些标记项自己的前后对比**（2026-11 改写）：不再拿「标记体积 ÷ 当前列表体积」
            // 给百分比 —— 标记的项还在列表里、分母又是整屏照片，200 MB 的标记只会显示 2.1%，
            // 看着像白标记了。用户要的是「这批删完/压完能降多少」。
            // 有选中时先不显示计数：底栏总宽 500，选中那一组按钮已经占满
            if store.trash.count > 0, store.selection.isEmpty {
                Button {
                    store.select(.trash)
                } label: {
                    Label("\(store.trash.count) 项 · \(markSizeText(store.trash.totalBytes, after: 0))",
                          systemImage: "trash")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("已标记回收 \(store.trash.count) 项：现在占 \(AppStore.sizeText(store.trash.totalBytes))，彻底删掉后归 0。点开进回收站，那里删才真正动设备")
            }

            if store.compression.count > 0, store.selection.isEmpty {
                let change = store.compressionSizeChange
                Button {
                    store.select(.compression)
                } label: {
                    Label("\(store.compression.count) 张 · \(markSizeText(change.before, after: change.after))",
                          systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.caption2)
                        .foregroundStyle(.brown)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("待压缩 \(store.compression.count) 张：现在 \(AppStore.sizeText(change.before))，按标记时选的比例/格式/质量压完约 \(AppStore.sizeText(change.after))（预估，不是整库占比）。点开进压缩站，那里压才真正动设备")
            }

            if let message = store.provisionalMessage {
                Text(message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    // 提示再长也不许把底栏顶出窗口
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-2)
                    .transition(.opacity)
            }

            Spacer(minLength: 12)

            if store.selection.isEmpty {
                // 有标记计数时优先给计数让位：底栏总宽只有 500
                if store.trash.count == 0 && store.compression.count == 0 {
                    hintChip
                }
            } else {
                Text("已选 \(store.selection.count) 项 · \(AppStore.sizeText(store.selectedBytes))")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()

                // 标记不二次确认：回收站本身就是那道保险
                Button {
                    store.markSelectedForRecycle()
                } label: {
                    Label("标记回收", systemImage: "trash")
                }
                .controlSize(.small)
                .help("打上回收标记（不需要二次确认），到回收站点「彻底删除」才真正从 iPhone 上删掉。同一项只能带一个标记：已经在压缩站的会被移出")

                // 「标记压缩」和「标记回收」同一套：只有选中了才出现、同一个位置、同一种按钮。
                // 点它只打开参数面板（那里面也只是标记），真压缩在「压缩站」。
                Button {
                    showConversion = true
                } label: {
                    Label("标记压缩", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .controlSize(.small)
                .help("只标记、不动手机：到「压缩站」确认后才真压。同一项只能带一个标记：已标回收的会被切到待压缩")

                Button("取消选择") { store.clearSelection() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        // 底栏高度**钉死**：换提示 / 换选中态时不许自己长高或缩矮。
        // 内容一律按小号控件排，保证 38pt 装得下，不会有任何东西把这一条顶高。
        .frame(height: 38)
        .background(.bar)
        .animation(.easeInOut(duration: 0.16), value: store.selection.isEmpty)
        .animation(.easeInOut(duration: 0.18), value: store.provisionalMessage)
    }

    /// 标记项的「现在 → 之后」。删掉的写 0，压缩写预估体积。
    /// **不再算占全库/列表的百分比**（见底栏那段注释）。
    private func markSizeText(_ before: Int64, after: Int64) -> String {
        "\(AppStore.sizeText(before)) → \(after == 0 ? "0" : AppStore.sizeText(after))"
    }

    /// 底栏右下角的操作提示：以前是一行 tertiary 小字，几乎看不见。
    /// 现在包一层胶囊、字号提到 caption、颜色从 tertiary 提到 secondary。
    private var hintChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 10, weight: .medium))
            Text("单击选中 · ⇧ 连选 · 拖动框选 · 空格预览")
                .font(.caption)
                // 窗口窄的时候先截这句，不许把胶囊顶出窗口
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .fixedSize(horizontal: false, vertical: true)
        .background(Capsule().fill(Color.secondary.opacity(0.10)))
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1))
        .help("⌘A 全选 · Esc 取消选择 · ⌘R 重新读取设备")
    }
}

/// 相簿二级栏：相簿列表（不是卡片）。只在侧栏选中「相簿」时出现。
/// 固定最小宽度 190，窗口再窄也不会被挤扁/裁掉，宁可让中间的图区变窄。
struct AlbumRail: View {
    @Environment(AppStore.self) private var store

    private var albums: [PhotoLibraryIndex.Album] {
        store.libraryAlbums.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                Text("相簿 · \(albums.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                ForEach(albums) { album in
                    row(album)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background.secondary.opacity(0.4))
    }

    private func row(_ album: PhotoLibraryIndex.Album) -> some View {
        let selected = store.albumFilter == album.id
        return Button {
            store.select(.album(album.id))
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
                Text(album.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(album.count) 张")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                    Text(AppStore.sizeText(store.albumBytes(album.id)))
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
        .help(album.title)
    }
}
