import AppKit
import SwiftUI

/// 回收站：标记过的东西都在这儿，**这里才是真正删的地方**。
/// 排序 / 搜索 / 视图切换 / 框选，和照片页一套手感。
struct TrashView: View {
    @Environment(AppStore.self) private var store

    enum SortKey: String, CaseIterable, Identifiable {
        case time, size
        var id: String { rawValue }
        var label: String { self == .time ? "时间" : "大小" }
    }

    @State private var search = ""
    @State private var sortKey: SortKey = .time
    @State private var ascending = false
    @State private var mode: ViewMode = .grid

    @State private var selection: Set<String> = []
    @State private var lastClicked: String?
    @State private var frames: [String: CGRect] = [:]
    @State private var marquee: CGRect?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            bottomBar
        }
        .animation(Motion.fade, value: store.trash.count)
        .task(id: store.trash.count) { requestThumbs() }
    }

    // MARK: - 顶栏

    private var header: some View {
        // 没有标题，控件整条居中（所有页面的顶栏都是这一条规矩）
        PageToolbar {
            HStack(spacing: 8) {
                SearchField(prompt: "搜索文件名", text: $search, width: 116)

                Picker("排序", selection: $sortKey) {
                    ForEach(SortKey.allCases) { key in
                        Text(key.label).tag(key)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 84)
                .help("按标记时间 / 按文件大小")

                // 升降序用文字，不用箭头
                Button {
                    ascending.toggle()
                } label: {
                    Text(ascending ? "升序" : "降序")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(width: 44, height: 20)
                }
                .buttonStyle(.bordered)
                .help(ascending ? "当前升序 · 点一下改为降序" : "当前降序 · 点一下改为升序")

                Picker("视图", selection: $mode) {
                    ForEach(ViewMode.allCases) { m in
                        Image(systemName: m.symbol).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 68)
                .help("缩略图视图 / 列表视图")
            }
        }
    }

    // MARK: - 数据

    /// 要显示的条目：搜索 + 排序
    private var shown: [TrashStore.Entry] {
        var items = store.trash.entries
        let needle = search.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            items = items.filter {
                $0.fileName.localizedStandardContains(needle)
                || $0.folder.localizedStandardContains(needle)
            }
        }
        switch sortKey {
        case .time: items.sort { $0.markedAt < $1.markedAt }
        case .size: items.sort { $0.byteSize < $1.byteSize }
        }
        if !ascending { items.reverse() }
        return items
    }

    /// 只用回收站里这几个 id 去翻资产表，不整表扫（5000 条 × 每一行 = 卡死）
    private var assetsByID: [String: Asset] {
        let wanted = Set(store.trash.entries.map(\.id))
        guard !wanted.isEmpty else { return [:] }
        var out: [String: Asset] = [:]
        for asset in store.assets where wanted.contains(asset.id) { out[asset.id] = asset }
        return out
    }

    private func requestThumbs() {
        let lookup = assetsByID
        for entry in store.trash.entries {
            guard let asset = lookup[entry.id] else { continue }
            store.requestThumbnail(asset)
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if store.trash.entries.isEmpty {
            EmptyStateView(icon: "trash",
                           title: "回收站是空的",
                           message: "在照片页勾选后点「标记回收」，东西会先到这里。放回去是瞬时的，清空才真正从 iPhone 上删除。")
        } else if shown.isEmpty {
            EmptyStateView(icon: "magnifyingglass",
                           title: "没有匹配的项",
                           message: "换个关键词，或者清空搜索框。",
                           actionTitle: "清空搜索") { search = "" }
        } else {
            switch mode {
            case .grid: grid
            case .list: list
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(shown) { entry in
                    cell(entry)
                }
            }
            .padding(10)
            .coordinateSpace(name: MarqueeSpace.trash)
            .onPreferenceChange(CellFramePreference.self) { frames = $0 }
            .overlay(alignment: .topLeading) {
                if let marquee { MarqueeRect(rect: marquee) }
            }
            .marqueeSelect(in: MarqueeSpace.trash, frames: frames, marquee: $marquee,
                           isSelected: { selection.contains($0) },
                           apply: { hits, mode in
                               switch mode {
                               case .select: selection.formUnion(hits)
                               case .deselect: selection.subtract(hits)
                               }
                           })
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(shown) { entry in
                    row(entry)
                }
            }
            .padding(.vertical, 4)
            .coordinateSpace(name: MarqueeSpace.trash)
            .onPreferenceChange(CellFramePreference.self) { frames = $0 }
            .overlay(alignment: .topLeading) {
                if let marquee { MarqueeRect(rect: marquee) }
            }
            .marqueeSelect(in: MarqueeSpace.trash, frames: frames, marquee: $marquee,
                           isSelected: { selection.contains($0) },
                           apply: { hits, mode in
                               switch mode {
                               case .select: selection.formUnion(hits)
                               case .deselect: selection.subtract(hits)
                               }
                           })
        }
    }

    // MARK: - 格子

    private func cell(_ entry: TrashStore.Entry) -> some View {
        let selected = selection.contains(entry.id)
        return Rectangle()
            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.18))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = store.thumbnails[entry.id] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: entry.isVideo ? "video" : "photo")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 3)
            }
            .overlay(alignment: .bottomLeading) {
                Text(ByteCountFormatter.string(fromByteCount: entry.byteSize, countStyle: .file))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .foregroundStyle(.white)
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .padding(6)
                    .opacity(selected ? 1 : 0)
            }
            .background(TrashFrameReporter(id: entry.id))
            .contentShape(Rectangle())
            .onTapGesture { click(entry) }
            .help("\(entry.fileName) · \(entry.folder)")
            .transition(.cellRemove)
            .contextMenu {
                Button("放回去") { store.restoreFromTrash(ids: [entry.id]) }
                Divider()
                Button("彻底删除…", role: .destructive) { askDelete(ids: [entry.id]) }
            }
    }

    // MARK: - 行

    private func row(_ entry: TrashStore.Entry) -> some View {
        let selected = selection.contains(entry.id)
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                if let image = store.thumbnails[entry.id] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipped()
                } else {
                    Image(systemName: entry.isVideo ? "video" : "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileName).font(.callout).lineLimit(1)
                Text("\(entry.createdAt.formatted(.dateTime.year().month().day().hour().minute())) · \(entry.folder)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(ByteCountFormatter.string(fromByteCount: entry.byteSize, countStyle: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .opacity(selected ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16) : .clear)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
        )
        .background(TrashFrameReporter(id: entry.id))
        .contentShape(Rectangle())
        .onTapGesture { click(entry) }
        .transition(.cellRemove)
        .contextMenu {
            Button("放回去") { store.restoreFromTrash(ids: [entry.id]) }
            Divider()
            Button("彻底删除…", role: .destructive) { askDelete(ids: [entry.id]) }
        }
    }

    // MARK: - 选择

    private func click(_ entry: TrashStore.Entry) {
        let list = shown
        if NSEvent.modifierFlags.contains(.shift),
           let anchor = lastClicked,
           let a = list.firstIndex(where: { $0.id == anchor }),
           let b = list.firstIndex(where: { $0.id == entry.id }) {
            let range = a <= b ? a...b : b...a
            selection.formUnion(list[range].map(\.id))
            return
        }
        if selection.contains(entry.id) {
            selection.remove(entry.id)
        } else {
            selection.insert(entry.id)
        }
        lastClicked = entry.id
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text("\(shown.count) 项 · \(AppStore.sizeText(shown.reduce(0) { $0 + $1.byteSize }))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if let message = store.purgeMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if selection.isEmpty {
                Button("全部放回去") {
                    store.restoreFromTrash(ids: store.trash.entries.map(\.id))
                }
                .disabled(store.trash.entries.isEmpty || store.isPurging)

                Button("清空回收站") { askDelete(ids: []) }
                    .disabled(store.trash.entries.isEmpty || store.isPurging)
                    .help("从 iPhone 上真正删除回收站里所有项")
            } else {
                Text("已选 \(selection.count) 项 · \(AppStore.sizeText(selectedBytes))")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()

                Button("放回去") {
                    store.restoreFromTrash(ids: Array(selection))
                    selection = []
                }

                Button(role: .destructive) {
                    askDelete(ids: Array(selection))
                } label: {
                    Label("彻底删除", systemImage: "trash.slash")
                }
                .help("从 iPhone 上真正删除这几项，无法恢复")

                Button("取消选择") { selection = [] }
            }
        }
        .padding(.horizontal, 18)
        // 和照片页一样：底栏高度固定，不随选中态变化
        .frame(height: 38)
        .background(.bar)
        .animation(Motion.fade, value: selection.isEmpty)
    }

    private var selectedBytes: Int64 {
        store.trash.entries.filter { selection.contains($0.id) }
            .reduce(0) { $0 + $1.byteSize }
    }

    /// 回收站里的所有删除动作都要走这里：先填好范围，再弹原生确认
    private func askDelete(ids: [String]) {
        store.pendingDeleteIDs = ids
        store.emptyTrashConfirmPresented = true
    }
}

private struct TrashFrameReporter: View {
    let id: String

    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: CellFramePreference.self,
                value: [id: geo.frame(in: .named(MarqueeSpace.trash))]
            )
        }
    }
}
