import AVKit
import SwiftUI

/// 独立预览层（类似 Quick Look）：盖住整个内容区，不改变选中项。
/// 打开目标由「鼠标悬停」决定：悬停哪一项，空格就预览哪一项。
///
/// 动画按 Quick Look 那套做：卡片从**被悬停那一格的中心**长出来（spring，0.34s），
/// 关闭时缩回去、缩完才真正拆状态（`store.isClosingPreview` 负责那 180 ms）。
struct PreviewOverlay: View {
    @Environment(AppStore.self) private var store
    @State private var player: AVPlayer?
    /// 实况照片的视频分量播放器（和整段视频的 `player` 分开：
    /// 一个是"这张照片在动"，一个是"这是个视频"，生命周期和位置都不同）
    @State private var livePlayer: AVPlayer?
    /// 播完观察者令牌，换目标时必须撤掉
    @State private var liveEndToken: NSObjectProtocol?
    /// 实况视频当前是不是在画面上。**不循环**：放一次就停，
    /// 用户点左上角「实况」才再放一次。
    @State private var livePlaying = false
    /// 进场 / 退场：只驱动缩放和透明度，不参与任何数据
    @State private var presented = false
    /// 「移入相簿」面板里的新建相簿输入框
    @State private var showNewAlbumField = false
    @State private var newAlbumTitle = ""

    private var asset: Asset? { store.previewAsset }

    var body: some View {
        GeometryReader { proxy in
            let anchor = anchorPoint(in: proxy.size)

            ZStack {
                // 全屏预览要盖死底下的界面：ultraThin 是半透明的，
                // 侧栏的勾选框会透上来（用户看到的"勾选框浮在预览上"就是它）。
                Rectangle()
                    .fill(.thickMaterial)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .opacity(presented ? 1 : 0)
                    .onTapGesture { store.closePreview() }

                VStack(spacing: 0) {
                    // 传下去的是**内层**宽度：外层有 28pt 左右内边距
                    topBar(available: proxy.size.width - 56)
                    // 按 M（或点「移入相簿」键帽）展开：每本相簿都是一颗可以直接点的按钮
                    if store.previewAlbumPicker {
                        albumPicker
                            .transition(.opacity)
                    }
                    media
                        // 从缩略图那一格长出来：锚点就是那一格的中心
                        .scaleEffect(presented ? 1 : 0.72, anchor: anchor)
                        .opacity(presented ? 1 : 0)
                    infoBar(available: proxy.size.width - 56)
                        .opacity(presented ? 1 : 0)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .animation(Motion.fade, value: store.previewAlbumPicker)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { presented = true }
        }
        .onChange(of: store.isClosingPreview) { _, closing in
            guard closing else { return }
            withAnimation(.easeIn(duration: 0.17)) { presented = false }
        }
        .onChange(of: store.previewVideoURL) { _, url in
            // 换目标时 loadPreviewImage 会先把 url 置空：这时必须把播放器一起放掉，
            // 否则 media 里 `if let player` 仍然成立，屏幕上还放着上一个视频。
            player?.pause()
            player = url.map { AVPlayer(url: $0) }
            player?.play()
        }
        .onChange(of: store.previewLiveVideoURL) { _, url in
            // 实况分量到了：盖在静态图上**放一次**。
            // 不放第二次 —— 想再看就点左上角那个「实况」。
            stopLivePlayback()
            guard let url else { return }
            let live = AVPlayer(url: url)
            live.isMuted = true
            // 播完只把画面撤掉，player 留着：再点时 seek 回 0 就能立刻放，
            // 不用重新建、不用重新解码
            if let item = live.currentItem {
                liveEndToken = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { _ in
                    livePlaying = false
                }
            }
            livePlayer = live
            livePlaying = true
            live.play()
        }
        .onChange(of: store.previewID) { _, _ in
            // 直接从一个视频跳到另一个（← →）也要停掉旧的，别让上一段在旁边接着放
            player?.pause()
            player = nil
            stopLivePlayback()
        }
        .onDisappear {
            player?.pause()
            stopLivePlayback()
        }
    }

    /// 停掉实况播放并撤掉播完观察者。
    /// 观察者必须显式 remove：`addObserver(forName:object:queue:using:)` 的 block 版
    /// 不会随 object 释放自动注销，留着就是每次换目标多一个常驻回调。
    private func stopLivePlayback() {
        livePlayer?.pause()
        livePlayer = nil
        livePlaying = false
        if let token = liveEndToken {
            NotificationCenter.default.removeObserver(token)
            liveEndToken = nil
        }
    }

    /// 点「实况」：从头再放一次
    private func replayLive() {
        guard let live = livePlayer else { return }
        live.seek(to: .zero)
        livePlaying = true
        live.play()
    }

    /// 缩放锚点：悬停那一格在 root 坐标系里的中心，归一化成 UnitPoint。
    /// 拿不到（用键盘开预览、从回收站开）就居中，不硬猜。
    private func anchorPoint(in size: CGSize) -> UnitPoint {
        guard let rect = store.previewAnchorRect,
              rect.width > 1, rect.height > 1,
              size.width > 1, size.height > 1 else { return .center }
        return UnitPoint(x: min(max(rect.midX / size.width, 0), 1),
                         y: min(max(rect.midY / size.height, 0), 1))
    }

    // MARK: - 顶栏

    /// 顶栏：**第一行名字、第二行键帽，键帽整排居中**（2026-11 用户定的）。
    ///
    /// 以前做过「宽窗口单行居中 + 键帽贴右」的自适应：但同一排键帽一会儿贴右、
    /// 一会儿换行，和照片页那条居中的快捷键条对不上；用户要的是两处都居中、大小一致。
    /// 现在固定两行：名字那行左右都有等宽留白（右边补一块和关闭按钮同宽的空位），
    /// 键帽那行用 `ViewThatFits` 挑一档 `HintDensity` 并居中 —— 窄了只整体缩小，不删字。
    private func topBar(available: CGFloat) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                closeButton
                // 状态胶囊本身就不短（「待压缩 60%·HEIC·Q80」），窗口太窄时先把它收起来
                titleBlock(showsPill: available >= 440)
                    .frame(maxWidth: .infinity)
                Color.clear.frame(width: 24, height: 24)
            }
            hintRow
        }
        .padding(.bottom, 12)
    }

    private var closeButton: some View {
        Button {
            store.closePreview()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.quaternary))
        }
        .buttonStyle(.plain)
        .help("关闭（Esc / 空格）")
    }

    /// 名字 + 「第几张 · 类型」+ 状态胶囊。宽度全交给外层，自己只负责不许撑破：
    /// 文件名中点截断，下面一行让读数先缩、状态胶囊不让。
    private func titleBlock(showsPill: Bool) -> some View {
        VStack(spacing: 1) {
            if let asset {
                Text(asset.fileName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("\(indexText) · \(asset.kind.label)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if showsPill {
                        statePill
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
            }
        }
    }

    /// 提示从右下角搬到顶部，而且**本身就是按钮** ——
    /// 既能看快捷键，也能直接点着用。
    /// `ViewThatFits` 从 normal → compact → tiny 挑第一档装得下的，**文字一个字都不删**；
    /// 和照片页那条快捷键条用同一个 `ShortcutKeyButton`、同一套字号。
    private var hintRow: some View {
        ViewThatFits(in: .horizontal) {
            hintButtons(.normal)
            hintButtons(.compact)
            hintButtons(.tiny)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func hintButtons(_ density: HintDensity) -> some View {
        HStack(spacing: density.spacing) {
            hintButton("空格", "关闭", density) { store.closePreview() }
            hintButton("← →", "下一张", density) { store.stepPreview(1) }
            // 已标记回收 / 待压缩的项也能选中（2026-11 用户改的：选中和标记分开）
            hintButton("⏎", isSelected ? "取消选中" : "选中", density) { store.togglePreviewSelection() }
            hintButton("⌫", isPending ? "取消删除" : "标记回收", density) {
                if isPending { store.unmarkCurrentPreview() }
                else { store.trashCurrentPreview() }
            }
            // 2026-11 用户定：**压缩用 Y**（不再用 `-`），和 ⌫ 互斥、再按一次取消
            hintButton("Y", isCompressionQueued ? "取消压缩" : "标记压缩", density) {
                store.compressionMarkCurrentPreview()
            }
            // 2026-11 用户定：**收藏用 L**（不再拿 ♥ 当键帽），只暂存，到修改站写回
            hintButton("L", isFavorite ? "取消收藏" : "收藏", density) {
                if let asset { store.toggleFavorite([asset]) }
            }
            // 移入相簿：点一下展开下面那一排相簿按钮（每本直接点）
            hintButton("M", store.previewAlbumPicker ? "收起相簿" : "移入相簿", density) {
                store.previewAlbumPicker.toggle()
            }
        }
        // 这一排按自然宽度排：`ViewThatFits` 量到的就是真实宽度，选中状态变文字时也不会抖。
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - 移入相簿（M）

    /// 按 M / 点顶栏「移入相簿」后展开的这一排：
    /// **每本相簿（包括还没写回的新相簿）都是一颗按钮，点一下直接暂存当前这张**。
    /// 顺序和照片页快捷面共用 `store.albumShortcutChoices`（拖过顺序后，键帽和视觉顺序一致）。
    private var albumPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("移到相簿")
                    .font(.system(size: 12, weight: .semibold))
                Text("按右边的键直接移入")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                if let from = fromAlbumTitle {
                    Text("会从「\(from)」移出")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("只加入相簿，不从别处移出")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if store.albumFilter != nil {
                    Button("只从当前相簿移出") {
                        store.stageRemoveCurrentPreviewFromAlbum()
                        store.previewAlbumPicker = false
                    }
                    .controlSize(.small)
                }
                // 已经暂存过移动的，给一条撤回路（和底栏的「取消移入」同一个口径）
                if stagedAlbum != nil {
                    Button("取消移入") {
                        if let asset { store.unmarkMoves([asset.id]) }
                    }
                    .controlSize(.small)
                }
                Button(showNewAlbumField ? "取消新建" : "新建相簿…") {
                    showNewAlbumField.toggle()
                    if !showNewAlbumField { newAlbumTitle = "" }
                }
                .controlSize(.small)
                Button {
                    store.previewAlbumPicker = false
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("收起（M）")
            }

            if showNewAlbumField {
                HStack(spacing: 8) {
                    TextField("新相簿名", text: $newAlbumTitle)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit { createAlbumAndMove() }
                    Button("新建并移入") { createAlbumAndMove() }
                        .controlSize(.small)
                        .disabled(newAlbumTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)],
                          alignment: .leading, spacing: 6) {
                    ForEach(store.albumShortcutChoices) { choice in
                        albumChip(choice)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: 150)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 10)
    }

    private var fromAlbumTitle: String? {
        guard let id = store.albumFilter else { return nil }
        return store.libraryAlbums.first { $0.id == id }?.title
    }

    private var stagedAlbum: PhotoEditQueue.AlbumRef? {
        guard let asset else { return nil }
        return store.edits.moveTarget(for: asset.id)
    }

    private func albumChip(_ choice: AlbumChoice) -> some View {
        let isTarget = stagedAlbum?.id == choice.id
        let shortcut = store.albumShortcutKey(for: choice.id)
        return Button {
            store.stageMoveCurrentPreview(to: choice)
            // 移完就收起面板：一次动作一个结果，不留在原地
            store.previewAlbumPicker = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isTarget
                      ? "checkmark.circle.fill"
                      : (choice.isNew ? "rectangle.stack.badge.plus" : "rectangle.stack"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isTarget ? AnyShapeStyle(Color.pink) : AnyShapeStyle(.secondary))
                Text(choice.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // 面板打开时按这颗键就直接移入（不再二次确认）
                if let shortcut {
                    AlbumShortcutKeyCap(key: shortcut)
                }
                Spacer(minLength: 4)
                Text(choice.isNew
                     ? (choice.count > 0 ? "待新建 · \(choice.count)" : "待新建")
                     : "\(choice.count)")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isTarget ? Color.pink.opacity(0.20) : Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isTarget ? Color.pink.opacity(0.75) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isTarget
              ? "这一张已经暂存到「\(choice.title)」"
              : (shortcut.map { "把这一张暂存到「\(choice.title)」（面板打开时按 \($0) 直接移入；写回手机才生效）" }
                 ?? "把这一张暂存到「\(choice.title)」（写回手机才生效）"))
    }

    private func createAlbumAndMove() {
        let title = newAlbumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        store.stageNewAlbumForCurrentPreview(title: title)
        newAlbumTitle = ""
        showNewAlbumField = false
        store.previewAlbumPicker = false
    }

    /// 当前这一项的状态胶囊。**标记和选中可以同时存在**（2026-11 用户改的）：
    /// 左边是标记（回收 / 待压缩 / 已暂存相簿），右边是「已选中」，两颗一起显示。
    @ViewBuilder
    private var statePill: some View {
        HStack(spacing: 4) {
            if isPending {
                pill("已标记回收", symbol: "trash.fill", tint: .orange)
            } else if isCompressionQueued {
                // 带上这张会怎么压：和格子上的角标同一套口径
                pill(compressionProfile.map { "待压缩 \($0.label)" } ?? "待压缩",
                     symbol: "arrow.down.right.and.arrow.up.left", tint: .brown)
            } else if let stagedAlbum {
                pill("→ \(stagedAlbum.title)", symbol: "rectangle.stack.fill", tint: .pink)
            }
            if isSelected {
                pill("已选中", symbol: "checkmark.circle.fill", tint: .accentColor)
            }
        }
    }

    private func pill(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    /// 键帽 + 文字，整个是一颗按钮：键帽告诉你快捷键，点它直接执行。
    /// 三档只差字号和内边距 —— **文字永远在**（用户定的）。
    /// 样式统一走 `ShortcutKeyButton`（照片页那条快捷键条用的是同一个组件）
    private func hintButton(_ key: String,
                            _ label: String,
                            _ density: HintDensity,
                            action: @escaping () -> Void) -> some View {
        ShortcutKeyButton(key: key, label: label, density: density, action: action)
    }

    private var indexText: String {
        let list = store.visibleAssets
        guard let id = store.previewID, let index = list.firstIndex(where: { $0.id == id }) else { return "" }
        return "\(index + 1) / \(list.count)"
    }

    // MARK: - 媒体

    private var media: some View {
        ZStack {
            if let asset, asset.kind == .video {
                if let player {
                    framed(PlayerSurface(player: player))
                } else if let image = store.previewImage {
                    framed(Image(nsImage: image).resizable().aspectRatio(contentMode: .fit))
                        .overlay { videoOverlay }
                } else {
                    // 还没缩略图、也还没起播：这一格以前是**全空**，
                    // 看着像预览坏了。现在至少给个进度/错误提示。
                    Color.clear
                        .frame(width: 420, height: 240)
                        .overlay { videoOverlay }
                }
            } else if let image = store.previewImage {
                framed(Image(nsImage: image).resizable().aspectRatio(contentMode: .fit))
                    // 实况：视频分量直接盖在静态图上，静态图永远是打底的
                    // （视频没到、解析失败时，看到的还是这张照片本身）
                    .overlay { liveLayer }
                    .overlay(alignment: .topLeading) {
                        if let asset, store.isLivePhoto(asset) {
                            liveBadge
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let error = store.previewError {
                            // 原图没取到时界面里只剩缩略图，必须说清楚，
                            // 别让人以为看到的就是原图
                            Text("\(error) · 当前显示的是缩略图")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.bottom, 10)
                        } else if store.previewLoading {
                            // 糊图已经在了，原图还在取：把「在等什么、还有多久」摆出来。
                            // 没有这一条，20 MB 的原图就是干晾着一张糊图。
                            photoProgressBadge
                        }
                    }
            } else {
                // 照片还没解出来（常见于正在等库索引）：给同一张卡片，别只给个转圈
                Color.clear
                    .frame(width: 420, height: 240)
                    .overlay { videoOverlay }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 实况的视频分量。盖在静态图上，不接鼠标事件（点击/缩放都归下层那张图）。
    @ViewBuilder
    private var liveLayer: some View {
        if let livePlayer, livePlaying {
            PlayerSurface(player: livePlayer, showsControls: false)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .allowsHitTesting(false)
        }
    }

    /// 大图取回中：糊图打底，底下报字节。
    /// 和视频那张卡片同一套口径（阶段文案 + 字节），只是缩小到不挡内容。
    private var photoProgressBadge: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text(store.previewLoadingHint)
                    .font(.system(size: 11.5, weight: .medium))
                if !store.previewProgressText.isEmpty {
                    Text(store.previewProgressText)
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if store.previewBytesTotal > 0 {
                ProgressView(value: store.previewBytesFraction)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 14)
    }

    /// 左上角「实况」角标，**同时是重播按钮**。
    /// 放一次就停（不循环）——想再看就点它，不点就一直停在静态图上。
    private var liveBadge: some View {
        Button {
            replayLive()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: livePlaying ? "livephoto.play" : "livephoto")
                    .font(.system(size: 9, weight: .semibold))
                Text(liveBadgeText)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(liveCanReplay ? 0.62 : 0.5), in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!liveCanReplay)
        .help(liveCanReplay ? "播一遍实况" : (livePlaying ? "正在播放" : "实况片段还在取回"))
        .padding(10)
        .animation(Motion.fade, value: livePlaying)
    }

    private var liveBadgeText: String {
        if livePlaying { return "实况" }
        if store.previewLiveVideoURL == nil { return "实况 · 正在取回" }
        return "实况 · 点击播放"
    }

    private var liveCanReplay: Bool {
        store.previewLiveVideoURL != nil && !livePlaying
    }

    /// 图片外框：圆角 + 状态描边（选中 = 强调色，标记 = 橙色）+ 投影
    private func framed<V: View>(_ content: V) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(stateBorderColor, lineWidth: 3)
            }
            .shadow(color: .black.opacity(0.28), radius: 24, y: 8)
    }

    private var stateBorderColor: Color {
        if isPending { return .orange }
        if isSelected { return .accentColor }
        if stagedAlbum != nil { return .pink.opacity(0.9) }
        return .clear
    }

    private var videoOverlay: some View {
        VStack(spacing: 10) {
            if store.previewError == nil {
                ProgressView().controlSize(.large)
                // 两行分开：「正在取回视频」是固定文案，不随数字宽度变；
                // 数字单独一行、等宽字体、固定宽度，1 MB → 100 MB 时只有数字在变。
                VStack(spacing: 2) {
                    Text(store.previewLoadingHint)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !store.previewProgressText.isEmpty {
                        Text(store.previewProgressText)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(width: 300)
                    }
                }
                // 确定性进度条：知道总量就画比例，不知道就只留转圈
                if store.previewBytesTotal > 0 {
                    ProgressView(value: store.previewBytesFraction)
                        .progressViewStyle(.linear)
                        .frame(width: 300)
                }
                Text("取回期间可以按 Esc 关掉，不影响继续浏览")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                Text(store.previewError ?? "")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button("重试") { store.openPreview() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.bottom, 12)
    }

    // MARK: - 信息条

    /// 窗口窄的时候先把「类型 / 格式 / 相簿」那三列收起来（它们在窄窗口里顶到窗口外面，
    /// 顺带把右边「已选 N 项」挤没了）。分辨率和体积是第一眼要看的，永远留。
    private func infoBar(available: CGFloat) -> some View {
        let showsDetails = available >= 660
        return HStack(alignment: .center, spacing: 24) {
            if let asset {
                // 分辨率和体积是第一眼要看到的信息，日期退到第二行
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(asset.resolutionText)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(AppStore.sizeText(store.byteSize(of: asset)))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        if let duration = asset.durationText {
                            Text(duration)
                                .font(.system(size: 18, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(asset.dateText)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }

                if showsDetails {
                    Divider().frame(height: 30)

                    HStack(spacing: 20) {
                        infoItem("类型", store.isLivePhoto(asset) ? "实况照片" : asset.kind.label)
                        infoItem("格式", asset.fileExtension)
                        infoItem("相簿", asset.folder)
                        if asset.isCloudOnly {
                            infoItem("来源", "仅云端")
                        }
                    }
                }

                Spacer()

                // 选中 / 标记的入口都在顶栏那一排键帽上（可点），
                // 这里只留状态读数，不再重复放两个按钮。
                VStack(alignment: .trailing, spacing: 1) {
                    if store.selection.isEmpty {
                        Text("未选中任何项")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        // 预览里也要看到「已选几项 · 占多少空间」
                        Text("已选 \(store.selection.count) 项")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(AppStore.sizeText(store.selectedBytes))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
                .frame(minWidth: 96, alignment: .trailing)
            }
        }
        .padding(.top, 14)
    }

    /// 暂存的收藏改动优先于库里的状态：预览里点完要立刻看到变化
    private var isFavorite: Bool {
        guard let asset else { return false }
        return store.displayedFavorite(asset)
    }

    private var isSelected: Bool {
        guard let asset else { return false }
        return store.selection.contains(asset.id)
    }

    private var isPending: Bool {
        guard let asset else { return false }
        return store.isPending(asset.id)
    }

    private var isCompressionQueued: Bool {
        guard let asset else { return false }
        return store.isQueuedForCompression(asset.id)
    }

    /// 这一项标记时选的压缩参数（预览状态胶囊里直接写出来）
    private var compressionProfile: ConversionProfile? {
        guard let asset else { return nil }
        return store.compressionProfile(for: asset.id)
    }

    private func infoItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}


/// 键帽的**密度**（预览顶栏 / 照片页快捷键条共用）：越窄字号和内边距越小，但文字一个都不删。
///
/// 2026-11 用户定的：窄窗口里不许把「关闭 / 下一张 / 选中 / 标记回收 / 标记压缩 / 收藏 / 移入相簿」收起来，
/// 只许整体缩小 —— 键帽本身是按钮，缩了还能点，删了等于把功能藏起来。
/// 三档的宽度大致是 **680 / 583 / 497pt**（7 颗按钮 + 间距，中文标签那版）。
/// 挑哪一档由 `ViewThatFits` 按真实宽度决定（normal → compact → tiny），不写死窗口阈值，
/// 所以预览和缩略图页在同一宽度下拿到的是同一个字号。
enum HintDensity {
    case normal, compact, tiny

    var keyFont: CGFloat {
        switch self {
        case .normal: return 12
        case .compact: return 10.5
        case .tiny: return 9.5
        }
    }

    var labelFont: CGFloat {
        switch self {
        case .normal: return 12.5
        case .compact: return 10.5
        case .tiny: return 9.5
        }
    }

    var keyMinWidth: CGFloat {
        switch self {
        case .normal: return 22
        case .compact: return 18
        case .tiny: return 16
        }
    }

    var keyPadding: CGFloat {
        switch self {
        case .normal: return 4
        case .compact: return 3
        case .tiny: return 2
        }
    }

    var keyPaddingV: CGFloat {
        switch self {
        case .normal: return 3
        case .compact: return 2
        case .tiny: return 1.5
        }
    }

    var buttonPadding: CGFloat {
        switch self {
        case .normal: return 6
        case .compact: return 4.5
        case .tiny: return 3
        }
    }

    var buttonPaddingV: CGFloat {
        switch self {
        case .normal: return 3
        case .compact: return 2
        case .tiny: return 1.5
        }
    }

    /// 键帽和文字之间
    var keyToLabel: CGFloat {
        switch self {
        case .normal: return 5
        case .compact: return 4
        case .tiny: return 3.5
        }
    }

    /// 按钮之间
    var spacing: CGFloat {
        switch self {
        case .normal: return 6
        case .compact: return 5
        case .tiny: return 4
        }
    }
}

/// 用 AppKit 的 AVPlayerView 播放，避开 SwiftUI VideoPlayer 在当前系统上的崩溃
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    /// 实况照片的视频分量盖在静态图上，不能带播放控件（3 秒的片段弹一排按钮很怪）
    var showsControls = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = showsControls ? .inline : .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
