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
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
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
            player?.pause()
            player = url.map { AVPlayer(url: $0) }
            player?.play()
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
                }
            } else if let image = store.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.28), radius: 24, y: 8)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var videoOverlay: some View {
        VStack(spacing: 10) {
            if store.previewError == nil {
                ProgressView().controlSize(.large)
                Text(store.previewProgressText.isEmpty ? "正在从 iPhone 取回视频…" : store.previewProgressText)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                Text("大视频需要一点时间，取回后会直接播放")
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
