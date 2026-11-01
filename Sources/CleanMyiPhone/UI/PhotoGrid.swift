import AppKit
import SwiftUI

struct PhotoGrid: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 6
            let minCell: CGFloat = 118
            let usable = max(proxy.size.width - spacing, minCell)
            let cols = max(1, Int(usable / (minCell + spacing)))

            ScrollView {
                // 用「一个网格 + 分组标题占满整行」的写法。
                // 之前是 LazyVStack 里再套 LazyVGrid + 吸顶分组，
                // 两层懒加载叠在一起在点「全部照片」时会直接把进程写崩。
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing),
                                         count: cols),
                          spacing: spacing,
                          pinnedViews: []) {
                    if store.showsDateSections {
                        ForEach(store.assetSections, id: \.id) { section in
                            Section {
                                ForEach(section.assets) { asset in
                                    PhotoCell(asset: asset)
                                }
                            } header: {
                                DateHeader(title: section.title, count: section.assets.count)
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
            }
            .onAppear { if store.columns != cols { store.columns = cols } }
            .onChange(of: cols) { _, newValue in
                if store.columns != newValue { store.columns = newValue }
            }
        }
    }
}

/// 时间轴小标题：年份/月份/日期 + 项数，吸顶
struct DateHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        // 和网格左边缘对齐（格子外侧 padding 是 6），否则标题会看着"缩进一格"
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

struct PhotoCell: View {
    let asset: Asset
    @Environment(AppStore.self) private var store
    @State private var hovering = false

    private var isSelected: Bool { store.selection.contains(asset.id) }
    private var isPending: Bool { store.pendingDeletions.contains(asset.id) }

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.22))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = store.thumbnails[asset.id] {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else if asset.kind == .video {
                    // 视频没有缩略图（要出图得整份下几十上百 MB），
                    // 给一个「一看就知道是视频、不是没加载」的占位，
                    // 别让它跟「加载失败」长得一样。
                    ZStack {
                        Rectangle().fill(Color.black.opacity(0.18))
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                } else {
                    Image(systemName: asset.kind.symbol)
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            // 选中：图面压暗一点，勾才看得清
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                }
            }
            // 打标记（待删）：橙色压一层 + 底部一条橙边，一眼能认出来
            .overlay {
                if isPending {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.orange.opacity(0.20))
                }
            }
            .overlay(alignment: .bottom) {
                if isPending {
                    Rectangle()
                        .fill(Color.orange)
                        .frame(height: 3)
                        .padding(.horizontal, 1)
                }
            }
            .overlay(alignment: .topLeading) { topBadges }
            .overlay(alignment: .bottomLeading) { durationBadge }
            .overlay(alignment: .bottomTrailing) { sizeBadge }
            // 悬停：白色 2pt 内描边；选中：accent 3pt。两者互斥，不叠加。
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.accentColor
                            : (hovering ? Color.white.opacity(0.9) : .clear),
                            lineWidth: isSelected ? 3 : 2)
            }
            .shadow(color: .black.opacity(hovering && !isSelected ? 0.22 : 0),
                    radius: hovering ? 5 : 0, y: hovering ? 2 : 0)
            // 不做 scaleEffect：格子被放大后会从鼠标下面"长走"，
            // 触发 leave→shrink→enter 的循环，手感就是"悬停不灵敏、忽明忽暗"。
            .contentShape(Rectangle())
            .zIndex(hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.1), value: hovering)
            .onHover { inside in
                hovering = inside
                store.setHover(asset.id, active: inside)
            }
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
            .help("\(asset.fileName)\n\(asset.dateText)\n\(asset.sizeText) · \(asset.resolutionText)\n空格预览 · ⌘点加选")
    }

    private var topBadges: some View {
        HStack(spacing: 4) {
            if asset.isCloudOnly { iconBadge("icloud.and.arrow.down") }
            if isPending { iconBadge("trash.fill", tint: .orange) }
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
            }
        }
        .padding(5)
    }

    private var durationBadge: some View {
        Group {
            if let duration = asset.durationText {
                Text(duration)
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .foregroundStyle(.white)
                    .padding(5)
            }
        }
    }

    private var sizeBadge: some View {
        Text(asset.sizeText)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(.black.opacity(0.55)))
            .foregroundStyle(.white)
            .padding(5)
    }

    private func iconBadge(_ symbol: String, tint: Color = .white) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .semibold))
            .padding(3)
            .background(Circle().fill(.black.opacity(0.55)))
            .foregroundStyle(tint)
    }
}
