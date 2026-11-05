import AppKit
import SwiftUI

struct PhotoList: View {
    @Environment(AppStore.self) private var store

    @State private var frames: [Asset.ID: CGRect] = [:]
    @State private var marquee: CGRect?

    var body: some View {
        ScrollView {
            content
                .coordinateSpace(name: MarqueeSpace.list)
                .onPreferenceChange(CellFramePreference.self) { frames = $0 }
                .overlay(alignment: .topLeading) {
                    if let marquee { MarqueeRect(rect: marquee) }
                }
                .marqueeSelect(in: MarqueeSpace.list, frames: frames, marquee: $marquee,
                               isSelected: { store.selection.contains($0) },
                               apply: { hits, mode in store.marqueeApply(hits, mode: mode) })
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.showsDateSections {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(store.assetSections, id: \.id) { section in
                    Section {
                        ForEach(section.assets) { asset in
                            PhotoRow(asset: asset)
                        }
                    } header: {
                        DateHeader(title: section.title, count: section.assets.count, pinned: true)
                    }
                }
            }
            .padding(.vertical, 4)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(store.visibleAssets) { asset in
                    PhotoRow(asset: asset)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// 列表里的一行。三种状态和缩略图视图一一对应：悬停 / 选中 / 标记回收。
struct PhotoRow: View {
    let asset: Asset
    @Environment(AppStore.self) private var store
    /// 同 `PhotoCell`：`CMI_DEMO_HOVER=1` 时初始就是悬停态（截图回归用）
    @State private var hovering = ProcessInfo.processInfo.environment["CMI_DEMO_HOVER"] != nil

    private var isSelected: Bool { store.selection.contains(asset.id) }
    private var isPending: Bool { store.isPending(asset.id) }
    private var isQueuedForCompression: Bool { store.isQueuedForCompression(asset.id) }
    /// 这一张标记时选的参数（行尾直接写出「怎么压」）
    private var compressionProfile: ConversionProfile? { store.compressionProfile(for: asset.id) }
    private var compression: CompressionDisplay? { store.compressionDisplay(for: asset) }
    private var isCompressedCopy: Bool { compression?.role == .copy }
    /// 暂存要移到哪本相簿（还没写回手机）
    private var stagedAlbum: PhotoEditQueue.AlbumRef? { store.edits.moveTarget(for: asset.id) }
    private var hasThumbnail: Bool { store.thumbnails[asset.id] != nil }

    var body: some View {
        HStack(spacing: 10) {
            thumb

            Text(asset.fileName)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isPending ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))

            Text(asset.sizeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()

            if asset.isCloudOnly {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if isPending {
                // 2026-11 用户改的：已标记的行也能选中；取消标记走底栏 / 右键的「取消删除」
                Label("已标记", systemImage: "trash.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .transition(.badge)
            }
            if let compression, compression.role == .copy {
                Text("已压缩 · \(compression.detailLabel)")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .transition(.badge)
            }
            if isQueuedForCompression && !isPending {
                // 和「已标记」完全同一套，只是浅黄（灰的太不显眼）。
                // 文字写参数而不是「待压缩」：这一张会压成什么样，列表里就要看得见。
                Label(compressionProfile.map { "待压缩 \($0.badgeText)" } ?? "待压缩",
                      systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.caption2.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.black.opacity(0.78))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.yellow.opacity(0.95)))
                    .fixedSize()
                    .transition(.badge)
            }

            // 暂存「移到相簿」：和格子左下那枚角标同一套粉色，列表里也要看得见
            if let stagedAlbum {
                // 和格子上的胶囊一个口径：文字多宽就多宽，长名字取 10 个字
                Label("→ \(String(stagedAlbum.title.prefix(10)))", systemImage: "rectangle.stack.fill")
                    .font(.caption2.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.pink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.badge)
                    .help("本机暂存：移到「\(stagedAlbum.title)」（还没写回手机）")
            }

            Spacer(minLength: 8)

            Text(asset.dateText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)

            // 勾放最右边，和苹果的列表选择一致
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .opacity(isSelected ? 1 : 0)
                .scaleEffect(isSelected ? 1 : 0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(background)
        .background(CellFrameReporter(asset: asset))
        .overlay { HoverProbe(hovering: $hovering) { inside, rect in
            store.setHover(asset.id, active: inside)
            if inside { store.setPreviewAnchor(rect) }
        } }
        .contentShape(Rectangle())
        .task(id: store.thumbEpoch) { store.requestThumbnail(asset) }
        .animation(Motion.fade, value: hovering)
        .animation(Motion.pop, value: isSelected)
        .animation(Motion.pop, value: isPending)
        .animation(Motion.pop, value: isCompressedCopy)
        .animation(Motion.pop, value: hasThumbnail)
        .onTapGesture {
            // 单击就是勾选 / 取消勾选，累积多选；⇧ 连选
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
            // 已暂存 / 已标记的项，右键菜单也翻成「取消…」
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
              + (compression.map { "\n\($0.label)" } ?? ""))
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(fillColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
    }

    private var fillColor: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isPending { return Color.orange.opacity(0.12) }
        if isCompressedCopy { return Color.green.opacity(0.10) }
        if isQueuedForCompression { return Color.yellow.opacity(0.16) }
        // 悬停底色提亮：8% 太淡，看不出来鼠标在哪一行
        if hovering { return Color.secondary.opacity(0.16) }
        return .clear
    }

    private var thumb: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
            if let image = store.thumbnails[asset.id] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 30, height: 30)
                    .clipped()
                    .opacity(isPending ? 0.6 : 1)
                    .transition(.opacity)
            } else {
                Image(systemName: asset.kind.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isPending ? Color.orange.opacity(0.8)
                              : (isCompressedCopy ? Color.green.opacity(0.8) : .clear),
                              lineWidth: 1.5)
        }
    }
}

private struct CellFrameReporter: View {
    let asset: Asset

    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: CellFramePreference.self,
                value: [asset.id: geo.frame(in: .named(MarqueeSpace.list))]
            )
        }
    }
}
