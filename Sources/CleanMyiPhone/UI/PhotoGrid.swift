import AppKit
import SwiftUI

struct PhotoGrid: View {
    @Environment(AppStore.self) private var store

    /// 每个格子在网格坐标里的位置（框选用）
    @State private var frames: [Asset.ID: CGRect] = [:]
    @State private var marquee: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 8
            // 格子宽度**由用户调**（顶栏那根滑杆 / ⌘+ ⌘-），不再定死 118。
            // 网格只负责按可用宽度排几列：窗口拉宽多排一列，格子大小不变。
            let minCell = store.thumbCell
            let usable = max(proxy.size.width - spacing, minCell)
            let cols = max(1, Int(usable / (minCell + spacing)))

            ScrollView {
                // 用「一个网格 + 分组标题占满整行」的写法。
                // 之前是 LazyVStack 里再套 LazyVGrid + 吸顶分组，
                // 两层懒加载叠在一起在点「全部照片」时会直接把进程写崩。
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing),
                                         count: cols),
                          spacing: spacing,
                          // 2026-11 用户定的：日期标题**吸顶**（和列表一样），
                          // 但样式用网格这一套（纯文字 + 页面底色，不是列表那条 `.bar` 白条）
                          pinnedViews: [.sectionHeaders]) {
                    if store.showsDateSections {
                        ForEach(store.assetSections, id: \.id) { section in
                            Section {
                                ForEach(section.assets) { asset in
                                    PhotoCell(asset: asset)
                                }
                            } header: {
                                DateHeader(title: section.title, count: section.assets.count, pinned: true)
                                    .gridCellColumns(cols)
                            }
                        }
                    } else {
                        ForEach(store.visibleAssets) { asset in
                            PhotoCell(asset: asset)
                        }
                    }
                }
                .padding(spacing)
                .coordinateSpace(name: MarqueeSpace.grid)
                .onPreferenceChange(CellFramePreference.self) { frames = $0 }
                .overlay(alignment: .topLeading) {
                    if let marquee { MarqueeRect(rect: marquee) }
                }
                .marqueeSelect(in: MarqueeSpace.grid, frames: frames, marquee: $marquee,
                               isSelected: { store.selection.contains($0) },
                               apply: { hits, mode in store.marqueeApply(hits, mode: mode) })
            }
            .onAppear { if store.columns != cols { store.columns = cols } }
            .onChange(of: cols) { _, newValue in
                if store.columns != newValue { store.columns = newValue }
            }
        }
    }
}

/// 时间小标题：**一行纯文字**，不装卡片（用户定的：别做成卡片）。
/// 日期按苹果相册那种感觉放大到 18pt bold，项数跟在后面小一号、次要色。
/// 列表模式会吸顶，所以那时才需要在底下垫一层 bar —— 不吸顶的网格不画底。
struct DateHeader: View {
    let title: String
    let count: Int
    /// 吸顶（列表 / 网格都吸）时要一块底，否则格子会从字底下穿过去
    var pinned = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text("\(count.formatted()) 项")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background {
            if pinned {
                // 吸顶必须有一块不透明底，否则缩略图会从日期字底下穿过去。
                // 用**页面底色**（`.background`）而不是 `.bar`：列表那条白条就是这么来的，
                // 用户要的是网格这种「看不出底色」的观感 —— 盖住内容，但不额外加一层灰。
                Rectangle()
                    .fill(.background)
                    .padding(.horizontal, -8)
            }
        }
        .transition(.opacity)
    }
}

struct PhotoCell: View {
    let asset: Asset
    @Environment(AppStore.self) private var store
    /// `CMI_DEMO_HOVER=1` 时初始就是悬停态：只给界面回归截图用（悬停没法用鼠标脚本复现）
    @State private var hovering = ProcessInfo.processInfo.environment["CMI_DEMO_HOVER"] != nil

    private var isSelected: Bool { store.selection.contains(asset.id) }
    private var isPending: Bool { store.isPending(asset.id) }
    /// 已经标记待压缩（在压缩站里排队，**还没动设备**）
    private var isQueuedForCompression: Bool { store.isQueuedForCompression(asset.id) }
    /// 这一张标记时选的参数：格子上直接写出来（比例/格式/质量），
    /// 别让人非得进压缩站才知道自己标的是什么
    private var compressionProfile: ConversionProfile? { store.compressionProfile(for: asset.id) }
    private var compression: CompressionDisplay? { store.compressionDisplay(for: asset) }
    private var isCompressedCopy: Bool { compression?.role == .copy }
    /// 暂存成收藏 / 取消收藏（还没写回手机）
    private var stagedFavorite: Bool? { store.edits.favorite(for: asset.id) }
    /// 暂存要移到哪本相簿
    private var stagedAlbum: PhotoEditQueue.AlbumRef? { store.edits.moveTarget(for: asset.id) }
    /// 缩略图到了没有：新的一帧图要淡入，不能"啪"地出现
    private var hasThumbnail: Bool { store.thumbnails[asset.id] != nil }

    /// 圆角 / 角标 / 内边距都按格子大小缩放（`store.thumbScale`：84pt → 0.78，200pt → 1.7）。
    /// 格子宽度可调之后，写死的 6pt 内边距在小格子里挤成一团、在大格子里又像飘着。
    private var k: CGFloat { store.thumbScale }
    private func s(_ v: CGFloat) -> CGFloat { v * k }
    private var corner: CGFloat { s(8) }

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.18))
            .aspectRatio(1, contentMode: .fit)
            .overlay { thumbnail }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            // 状态铺色（选中 / 待删 / 待压缩 / 已压缩）一次画完，别写成四条 overlay 链
            .overlay { stateTint }
            .overlay(alignment: .topLeading) { leadingBadges }
            .overlay(alignment: .topTrailing) { cornerBadge }
            .overlay(alignment: .bottomLeading) { bottomLeadingBadges }
            .overlay(alignment: .bottomTrailing) { sizeBadge }
            .overlay { stateRing }
            // 悬停的"抬起来"：柔和的大阴影（苹果那种悬浮感，不是套两层框）
            .shadow(color: .black.opacity(hovering ? 0.34 : 0),
                    radius: hovering ? s(14) : 0, y: hovering ? s(5) : 0)
            .background(CellFrameReporter(asset: asset))
            .overlay {
                // 悬停层顺带记下这一格在 root 坐标系里的位置：预览卡片从这儿长出来
                HoverProbe(hovering: $hovering) { inside, rect in
                    store.setHover(asset.id, active: inside)
                    if inside { store.setPreviewAnchor(rect) }
                }
            }
            .contentShape(Rectangle())
            .zIndex(hovering ? 1 : 0)
            // 不做整个格子的 scaleEffect：格子被放大后会从鼠标下面"长走"，
            // 触发 leave→shrink→enter 的循环，手感就是"悬停不灵敏、忽明忽暗"。
            // 放大的只是里面那张图，外框尺寸和命中区域一点没变。
            .animation(Motion.fade, value: hovering)
            // 选中 / 标记 / 取消标记：苹果那种弹一下，不是干巴巴地换颜色
            .animation(Motion.pop, value: isSelected)
            .animation(Motion.pop, value: isPending)
            .animation(Motion.pop, value: isCompressedCopy)
            .animation(Motion.thumb, value: hasThumbnail)
            // 两个入口都要：
            // `.task` 管首次出现；`onAppear` 管「切排序/换筛选后被复用回来的格子」——
            // 复用的视图 id 没变，`.task(id:)` 不会重跑，内存缓存又被 LRU 淘汰掉了，
            // 于是一整屏都是空块、还永远不加载。
            .task(id: store.thumbEpoch) { store.requestThumbnail(asset) }
            .onAppear { store.requestThumbnail(asset) }
            .onTapGesture {
                // 单击就是勾选 / 取消勾选，选了第一个再点第二个会累积，
                // 不需要按住 ⌘；⇧ 仍然是连选。
                let flags = NSEvent.modifierFlags
                if flags.contains(.shift) {
                    store.extend(to: asset)
                } else {
                    store.toggle(asset)
                }
            }
            .contextMenu {
                Button(store.displayedFavorite(asset) ? "取消收藏" : "收藏") {
                    store.toggleFavorite(store.prepareContext(asset))
                }
                // 2026-11 用户定的新交互：已暂存 / 已标记的项，右键菜单也翻成「取消…」
                if store.edits.hasMove(asset.id) {
                    Button("取消移入相簿") { store.unmarkMoves([asset.id]) }
                } else {
                    Button("移动到相簿…") {
                        store.prepareContext(asset)
                        store.albumPanelOpen = true
                    }
                }
                Divider()
                if store.isPending(asset.id) {
                    Button("取消删除") { store.unmark([asset.id]) }
                } else {
                    Button("标记回收") {
                        store.prepareContext(asset)
                        store.markSelectedForRecycle()
                    }
                }
                Button("空格预览") {
                    store.prepareContext(asset)
                    store.openPreview()
                }
            }
            .help("\(asset.fileName)\n\(asset.dateText)\n\(asset.sizeText) · \(asset.resolutionText)"
                  + (compression.map { "\n\($0.label)" } ?? "")
                  + (compressionProfile.map { "\n标记压缩：\($0.label)（选中后底栏「取消压缩」或预览里按 Y 撤销）" } ?? "")
                  + "\n空格预览 · 拖动框选 · ⇧ 点连选")
    }

    // MARK: - 状态铺色 / 描边 / 悬停（拆开写：整条链一起写会类型检查超时）

    /// 一格只带一种状态色：选中（强调色）> 待删（橙）> 待压缩（浅黄）> 已压缩（绿）
    private var tintColor: Color {
        if isSelected { return Color.accentColor.opacity(0.14) }
        if isPending { return Color.orange.opacity(0.18) }
        if isQueuedForCompression { return Color.yellow.opacity(0.22) }
        if isCompressedCopy { return Color.green.opacity(0.12) }
        return .clear
    }

    private var stateTint: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(tintColor)
    }

    private var stateRing: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .strokeBorder(ringColor, lineWidth: ringWidth)
    }

    // MARK: - 描边

    private var ringColor: Color {
        if isSelected { return .accentColor }
        if isPending { return .orange }
        if isQueuedForCompression { return .yellow }
        if isCompressedCopy { return .green }
        // 悬停：一条干净的白色细边（苹果相册那种头发丝边），配合下面的柔和投影
        if hovering { return Color.white.opacity(0.78) }
        return .clear
    }

    private var ringWidth: CGFloat {
        // 描边跟着格子缩：200pt 的大格子上 3pt 太细、84pt 的小格子上太粗
        if isSelected { return s(3) }
        if isPending { return s(2.5) }
        if isQueuedForCompression { return s(2.5) }
        if isCompressedCopy { return s(2.5) }
        // 2pt：白底照片上也看得见，又不至于像"套了个框"（3pt + 外圈白晕＝丑）
        if hovering { return s(2) }
        return 0
    }

    // MARK: - 图

    private var thumbnail: some View {
        Group {
            if let image = store.thumbnails[asset.id] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    // 只放大里面的图：外框不动，不会抖
                    // 只放大里面的图：外框尺寸和命中区一点没变，不会触发 hover 抖动。
                    // 1.08 → 1.16：用户觉得 8% 看不出来
                    .scaleEffect(hovering ? 1.12 : 1.0)
                    .brightness(hovering ? 0.03 : 0)
                    // 标记之后压暗，一眼能分出"留"和"不要"
                    .opacity(isPending ? 0.55 : 1)
                    .transition(.opacity)
            } else if asset.kind == .video {
                // 视频没有缩略图：给一个「一看就知道是视频、不是没加载」的占位，
                // 别让它跟「加载失败」长得一样。
                ZStack {
                    Rectangle().fill(Color.black.opacity(0.18))
                    Image(systemName: "play.fill")
                        .font(.system(size: s(22), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .transition(.opacity)
            } else {
                Image(systemName: asset.kind.symbol)
                    .font(.system(size: s(20), weight: .light))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - 角标

    /// 左上角：云朵 + **垃圾桶**。垃圾桶比原来大一号 —— 用户要的就是"左上角一眼看到垃圾桶"。
    @ViewBuilder
    private var leadingBadges: some View {
        // 两行：第一行是状态（云端 / 待删 / 待压缩 / 已压缩），第二行是「→ 相簿名」。
        // 相簿角标 2026-11 从**左下搬到左上**：放左下时它一宽就压住右下角的体积，
        // 而左上本来就有一排状态角标，往下叠一行不会挡任何读数。
        VStack(alignment: .leading, spacing: s(3)) {
            HStack(spacing: s(3)) {
                if asset.isCloudOnly {
                    iconBadge("icloud.and.arrow.down", size: s(8), pad: s(3.5))
                        .transition(.badge)
                }
                if isPending {
                    iconBadge("trash.fill", glyph: .white, fill: .orange, size: s(10), pad: s(4.5))
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .transition(.badge)
                }
                // 待压缩：浅黄胶囊 + 深色字（黄底压白字读不出来）。
                // 文字从「待压缩」换成**这张会怎么压**：`60%·HEIC·Q80`（用户要每格都能看出参数）。
                if isQueuedForCompression && !isPending && !isCompressedCopy {
                    HStack(spacing: s(2)) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: s(6.5), weight: .bold))
                        Text(compressionProfile?.badgeText ?? "待压缩")
                            .font(.system(size: s(8), weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal, s(4))
                    .padding(.vertical, s(1.5))
                    .background(Capsule().fill(Color.yellow.opacity(0.95)))
                    .foregroundStyle(Color.black.opacity(0.78))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .transition(.badge)
                }
                if isCompressedCopy {
                    Text("已压缩")
                        .font(.system(size: s(8), weight: .bold))
                        .padding(.horizontal, s(4))
                        .padding(.vertical, s(1.5))
                        .background(Capsule().fill(Color.green))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .transition(.badge)
                }
            }
            if let stagedAlbum {
                albumBadge(stagedAlbum)
            }
        }
        .animation(Motion.pop, value: isPending)
        .animation(Motion.pop, value: isCompressedCopy)
        .animation(Motion.pop, value: isQueuedForCompression)
        .animation(Motion.pop, value: stagedAlbum)
        .padding(s(6))
    }

    /// 暂存「移到相簿」的角标：粉色胶囊 + 相簿名。
    /// **胶囊宽度跟着文字自适应**（`fixedSize`），短名字不会撑成一大块；
    /// 长名字最多显示 6 个字（再长会顶到右上角的选中勾），全名在 tooltip / 预览 / 列表行里。
    private func albumBadge(_ album: PhotoEditQueue.AlbumRef) -> some View {
        HStack(spacing: s(2.5)) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: s(8.5), weight: .bold))
            // 宽度跟着文字走：两个字就两个字的宽（用户 2026-11 报「相簿名太宽」）。
            // 长名字最多取 6 个字，避免顶到右上角的选中勾；完整名字在 tooltip 里。
            Text(String(album.title.prefix(6)))
                .font(.system(size: s(10.5), weight: .bold))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, s(5))
        .padding(.vertical, s(2.5))
        .background(Capsule(style: .continuous).fill(Color.pink.opacity(0.94)))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: s(0.9))
        )
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.3), radius: s(2), y: s(1))
        .transition(.badge)
        .help("本机暂存：移到「\(album.title)」（还没写回手机）")
    }

    /// 右上角只有「选中」那个勾。
    /// 2026-11 用户改的：**选中和标记分开** —— 已标记的格子也能被选中（勾 + 橙/黄角标同时出现），
    /// 撤销标记走底栏的「取消删除 / 取消压缩」或右键菜单，不再靠再点一下。
    @ViewBuilder
    private var cornerBadge: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: s(16)))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .padding(s(6))
                .transition(.badge)
        }
    }

    /// 左下：只放**收藏 / 时长**。
    /// 「→ 相簿名」2026-11 搬到了左上（见 `leadingBadges`）：
    /// 放左下时它一宽就压住右下角的体积角标，而用户明确说「太宽，挡到存储显示」。
    @ViewBuilder
    private var bottomLeadingBadges: some View {
        HStack(spacing: s(3)) {
            if let stagedFavorite {
                Image(systemName: stagedFavorite ? "heart.fill" : "heart.slash.fill")
                    .font(.system(size: s(9.5), weight: .bold))
                    .foregroundStyle(.white)
                    .padding(s(3.5))
                    .background(Circle().fill(Color.pink.opacity(0.92)))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .transition(.badge)
                    .help(stagedFavorite ? "本机暂存：收藏（还没写回手机）" : "本机暂存：取消收藏（还没写回手机）")
            }
            if let duration = asset.durationText {
                Text(duration)
                    .font(.system(size: s(9), weight: .semibold).monospacedDigit())
                    .padding(.horizontal, s(4))
                    .padding(.vertical, s(1))
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .foregroundStyle(.white)
            }
        }
        .animation(Motion.pop, value: stagedFavorite)
        .padding(s(6))
    }

    @ViewBuilder
    private var sizeBadge: some View {
        if let compression, compression.role == .copy {
            // 跟“选中/标记”一样用角标，不做整条底栏；两行小字，放不下自动缩。
            VStack(alignment: .leading, spacing: 0) {
                Text(compression.formatPercentLabel)
                Text(compression.qualitySizeLabel)
            }
            .font(.system(size: s(7.5), weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(.white)
            .padding(.horizontal, s(5))
            .padding(.vertical, s(2))
            .background(
                RoundedRectangle(cornerRadius: s(4), style: .continuous)
                    .fill(Color.green.opacity(0.92))
            )
            .padding(s(6))
        } else {
            Text(asset.sizeText)
                .font(.system(size: s(9), weight: .semibold))
                .padding(.horizontal, s(4))
                .padding(.vertical, s(1))
                .background(Capsule().fill(.black.opacity(0.55)))
                .foregroundStyle(.white)
                .padding(s(6))
        }
    }

    private func iconBadge(_ symbol: String,
                           glyph: Color = .white,
                           fill: Color = .black.opacity(0.55),
                           size: CGFloat,
                           pad: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .padding(pad)
            .background(Circle().fill(fill))
            .foregroundStyle(glyph)
    }
}

/// 把格子的位置报给上层（框选用）
private struct CellFrameReporter: View {
    let asset: Asset

    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: CellFramePreference.self,
                value: [asset.id: geo.frame(in: .named(MarqueeSpace.grid))]
            )
        }
    }
}
