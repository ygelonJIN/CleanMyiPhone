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
                    topBar
                    media
                        // 从缩略图那一格长出来：锚点就是那一格的中心
                        .scaleEffect(presented ? 1 : 0.72, anchor: anchor)
                        .opacity(presented ? 1 : 0)
                    infoBar
                        .opacity(presented ? 1 : 0)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
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

    private var topBar: some View {
        ZStack {
            // 标题居中，两侧各自独立，窄窗口下只截标题、不截提示
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
                        statePill
                    }
                }
            }
            .padding(.horizontal, 340)

            HStack(spacing: 0) {
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

                Spacer(minLength: 0)

                // 提示从右下角搬到顶部，而且**本身就是按钮** ——
                // 既能看快捷键，也能直接点着用。
                HStack(spacing: 6) {
                    hintButton("空格", "关闭") { store.closePreview() }
                    hintButton("← →", "下一张") { store.stepPreview(1) }
                    // 已标记回收的项不许再选中：它已经在待删名单里了
                    hintButton("⏎", isSelected ? "取消选中" : "选中",
                               enabled: !isPending) { store.togglePreviewSelection() }
                    hintButton("⌫", isPending ? "取消标记" : "标记回收") {
                        if isPending { store.unmarkCurrentPreview() }
                        else { store.trashCurrentPreview() }
                    }
                }
            }
        }
        .padding(.bottom, 12)
    }

    /// 当前这一项的状态胶囊：选中 / 已标记回收
    @ViewBuilder
    private var statePill: some View {
        if isPending {
            pill("已标记回收", symbol: "trash.fill", tint: .orange)
        } else if isSelected {
            pill("已选中", symbol: "checkmark.circle.fill", tint: .accentColor)
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

    /// 键帽 + 文字，整个是一颗按钮：键帽告诉你快捷键，点它直接执行
    private func hintButton(_ key: String,
                            _ label: String,
                            enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(key)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(minWidth: 26)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.quaternary)
                    )
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(enabled ? 0.10 : 0.04))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(enabled ? "\(key) · \(label)" : "已标记回收的项不能选中")
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

    private var infoBar: some View {
        HStack(alignment: .center, spacing: 24) {
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

                Divider().frame(height: 30)

                HStack(spacing: 20) {
                    infoItem("类型", store.isLivePhoto(asset) ? "实况照片" : asset.kind.label)
                    infoItem("格式", asset.fileExtension)
                    infoItem("相簿", asset.folder)
                    if asset.isCloudOnly {
                        infoItem("来源", "仅云端")
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

    private var isSelected: Bool {
        guard let asset else { return false }
        return store.selection.contains(asset.id)
    }

    private var isPending: Bool {
        guard let asset else { return false }
        return store.pendingDeletions.contains(asset.id)
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
