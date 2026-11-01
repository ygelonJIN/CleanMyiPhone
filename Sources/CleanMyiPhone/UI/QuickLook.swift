import AVKit
import SwiftUI

/// 独立预览层（类似 Quick Look）：盖住整个内容区，不改变选中项。
/// 打开目标由「鼠标悬停」决定：悬停哪一项，空格就预览哪一项。
struct PreviewOverlay: View {
    @Environment(AppStore.self) private var store
    @State private var player: AVPlayer?

    private var asset: Asset? { store.previewAsset }

    var body: some View {
        ZStack {
            // 全屏预览要盖死底下的界面：ultraThin 是半透明的，
            // 侧栏的勾选框会透上来（用户看到的"勾选框浮在预览上"就是它）。
            Rectangle()
                .fill(.thickMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { store.closePreview() }

            VStack(spacing: 0) {
                topBar
                media
                infoBar
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .onChange(of: store.previewVideoURL) { _, url in
            // 换目标时 loadPreviewImage 会先把 url 置空：这时必须把播放器一起放掉，
            // 否则 media 里 `if let player` 仍然成立，屏幕上还放着上一个视频。
            player?.pause()
            player = url.map { AVPlayer(url: $0) }
            player?.play()
        }
        .onChange(of: store.previewID) { _, _ in
            // 直接从一个视频跳到另一个（← →）也要停掉旧的，别让上一段在旁边接着放
            player?.pause()
            player = nil
        }
        .onDisappear { player?.pause() }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                store.closePreview()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")

            Spacer(minLength: 0)

            if let asset {
                VStack(spacing: 1) {
                    Text(asset.fileName)
                        .font(.headline)
                        .lineLimit(1)
                    // 取回进度只在中间那张卡片里显示，标题下面保持干净
                    Text("\(indexText) · \(asset.kind.label)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            // 和左侧关闭按钮对称，保证标题真居中
            Color.clear.frame(width: 24, height: 24)
        }
        .padding(.bottom, 12)
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
                    PlayerSurface(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.28), radius: 24, y: 8)
                } else if let image = store.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay { videoOverlay }
                } else {
                    // 还没缩略图、也还没起播：这一格以前是**全空**，
                    // 看着像预览坏了。现在至少给个进度/错误提示。
                    Color.clear
                        .frame(width: 420, height: 240)
                        .overlay { videoOverlay }
                }
            } else if let image = store.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.28), radius: 24, y: 8)
                    .overlay(alignment: .bottom) {
                        // 原图没取到时界面里只剩缩略图，必须说清楚，别让人以为看到的就是原图
                        if let error = store.previewError {
                            Text("\(error) · 当前显示的是缩略图")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.bottom, 10)
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
                    infoItem("类型", asset.kind.label)
                    infoItem("格式", asset.fileExtension)
                    infoItem("相簿", asset.folder)
                    if asset.isCloudOnly {
                        infoItem("来源", "仅云端")
                    }
                }

                Spacer()

                // 预览里就能选中 / 标记 / 删，不用退出去再点一遍
                Button {
                    store.togglePreviewSelection()
                } label: {
                    Label(isSelected ? "取消选中" : "选中",
                          systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                }
                .controlSize(.regular)
                .help("把当前这一项加入 / 移出选择（S）")

                Button {
                    store.togglePreviewSelection()
                    store.trashCurrentPreview()
                } label: {
                    Label("收进回收站", systemImage: "trash")
                }
                .controlSize(.regular)
                .help("打上删除标记并跳到下一项（⌫）")

                VStack(alignment: .trailing, spacing: 1) {
                    Text("空格关闭 · ← → 切换")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if !store.selection.isEmpty {
                        Text("已选 \(store.selection.count) 项")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 14)
    }

    private var isSelected: Bool {
        guard let asset else { return false }
        return store.selection.contains(asset.id)
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

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
