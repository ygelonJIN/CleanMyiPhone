import AppKit
import SwiftUI

/// 压缩站：**所有「标记压缩」都堆在这儿，这里才是真压的地方**。
///
/// 交互和「回收站」一模一样（用户定的）：搜索 / 排序（放入时间、大小）/ 升降序 /
/// 网格⇄列表 / 单击·⇧连选·框选 / 底栏批量操作。区别只有三处：
/// 1. 这里是**压缩**，只改本机 + 写回相册，没有不可逆操作（最坏是「从压缩站移除」）；
/// 2. 执行时**整批只写一次相册库**（约 300 MB 往返），所以先把要压的攒够；
/// 3. 压缩完一定写回手机相册 —— 不做成开关（不进相册等于没压）。
struct CompressionView: View {
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
        .animation(Motion.fade, value: store.compression.count)
        .animation(Motion.fade, value: selection.isEmpty)
        .task(id: store.compression.count) { requestThumbs() }
        // 压完（或移除后）选中里可能有已经不存在的 id：不清掉底栏会显示「已选 3 张」但框里没有
        .onChange(of: store.compression.entries) { _, entries in
            let alive = Set(entries.map(\.id))
            if !selection.isSubset(of: alive) {
                selection = selection.intersection(alive)
            }
        }
    }

    // MARK: - 顶栏（没有标题，控件整条居中）

    private var header: some View {
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
                .help("按放入压缩站的时间 / 按文件大小")

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

    private var shown: [CompressionQueue.Entry] {
        var items = store.compression.entries
        let needle = search.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            items = items.filter {
                $0.asset.fileName.localizedStandardContains(needle)
                || $0.asset.folder.localizedStandardContains(needle)
            }
        }
        switch sortKey {
        case .time: items.sort { $0.markedAt < $1.markedAt }
        case .size: items.sort { $0.asset.byteSize < $1.asset.byteSize }
        }
        if !ascending { items.reverse() }
        return items
    }

    private func requestThumbs() {
        for entry in store.compression.entries {
            store.requestThumbnail(entry.asset)
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if store.conversionRunning, let progress = store.conversionProgress {
            runningPanel(progress)
        } else if store.compression.isEmpty {
            EmptyStateView(
                icon: "arrow.down.right.and.arrow.up.left",
                title: "压缩站是空的",
                message: """
                在照片页选中照片 → 点「标记压缩」，那里只标记、不动手机。
                攒够一批回这里，点「开始压缩」才真的压（整批只写一次相册库）。
                """
            )
        } else if shown.isEmpty {
            EmptyStateView(icon: "magnifyingglass",
                           title: "没有匹配的项",
                           message: "换个关键词，或者清空搜索框。",
                           actionTitle: "清空搜索") { search = "" }
        } else {
            VStack(spacing: 0) {
                if let result = store.conversionResult {
                    resultBanner(result)
                    Divider()
                }
                switch mode {
                case .grid: grid
                case .list: list
                }
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
            .coordinateSpace(name: MarqueeSpace.compression)
            .onPreferenceChange(CellFramePreference.self) { frames = $0 }
            .overlay(alignment: .topLeading) {
                if let marquee { MarqueeRect(rect: marquee) }
            }
            .marqueeSelect(in: MarqueeSpace.compression, frames: frames, marquee: $marquee,
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
            .coordinateSpace(name: MarqueeSpace.compression)
            .onPreferenceChange(CellFramePreference.self) { frames = $0 }
            .overlay(alignment: .topLeading) {
                if let marquee { MarqueeRect(rect: marquee) }
            }
            .marqueeSelect(in: MarqueeSpace.compression, frames: frames, marquee: $marquee,
                           isSelected: { selection.contains($0) },
                           apply: { hits, mode in
                               switch mode {
                               case .select: selection.formUnion(hits)
                               case .deselect: selection.subtract(hits)
                               }
                           })
        }
    }

    // MARK: - 格子（和回收站同一套：选中环 + 勾 + 体积角标）

    private func cell(_ entry: CompressionQueue.Entry) -> some View {
        let selected = selection.contains(entry.id)
        return Rectangle()
            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.18))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = store.thumbnails[entry.id] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo")
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
                Text(ByteCountFormatter.string(fromByteCount: entry.asset.byteSize, countStyle: .file))
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
            .background(CompressionFrameReporter(id: entry.id))
            .contentShape(Rectangle())
            .onTapGesture { click(entry) }
            .help("\(entry.asset.fileName) · \(entry.profile.label)")
            .transition(.cellRemove)
            .contextMenu {
                Button("从压缩站移除") { store.compression.remove(ids: [entry.id]) }
            }
    }

    // MARK: - 行

    private func row(_ entry: CompressionQueue.Entry) -> some View {
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
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.asset.fileName).font(.callout).lineLimit(1)
                Text("\(entry.asset.folder) · \(entry.profile.label)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(ByteCountFormatter.string(fromByteCount: entry.asset.byteSize, countStyle: .file))
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
        .background(CompressionFrameReporter(id: entry.id))
        .contentShape(Rectangle())
        .onTapGesture { click(entry) }
        .transition(.cellRemove)
        .contextMenu {
            Button("从压缩站移除") { store.compression.remove(ids: [entry.id]) }
        }
    }

    // MARK: - 选择（单击 / ⇧ 连选；框选由 marqueeSelect 处理）

    private func click(_ entry: CompressionQueue.Entry) {
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

    // MARK: - 运行中 / 结果

    private func runningPanel(_ progress: PhotoConversionEngine.Progress) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: progress.total > 0
                         ? Double(progress.completed) / Double(progress.total) : 0)
                .frame(maxWidth: 320)
            Text("\(progress.phase) \(progress.completed)/\(progress.total)")
                .font(.callout)
                .monospacedDigit()
            if !progress.current.isEmpty {
                Text(progress.current)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(progress.phase == "改库"
                 ? "正在写库（约 300 MB），这一步会停一会儿…"
                 : "别拔线别锁屏；写库和重启相册这两步最慢")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func resultBanner(_ result: PhotoConversionEngine.Result) -> some View {
        let copyBytes = result.records.reduce(Int64(0)) { $0 + $1.newSize }
        let originalBytes = result.records.reduce(Int64(0)) { $0 + $1.originalSize }
        return VStack(alignment: .leading, spacing: 3) {
            if result.records.isEmpty {
                Text("上一次没成功：没有可压缩的项")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
            } else {
                Text("上一次：完成 \(result.records.count) 张 · 副本合计 \(AppStore.sizeText(copyBytes))（原图 \(AppStore.sizeText(originalBytes))）")
                    .font(.callout.weight(.medium))
                if originalBytes > copyBytes {
                    Text("原图已进回收站：彻底删除后净省 \(AppStore.sizeText(originalBytes - copyBytes))")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            ForEach(Array(result.failures.prefix(4).enumerated()), id: \.offset) { _, failure in
                Text("\(failure.name)：\(failure.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }

    // MARK: - 底栏（38pt 固定，和照片页 / 回收站一致）

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text("\(shown.count) 张 · \(AppStore.sizeText(shownBytes))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if store.conversionRunning {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("正在压缩 \(store.conversionProgress?.completed ?? 0) / \(store.conversionProgress?.total ?? 0) 张…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else if store.compression.groups.count > 1 {
                Text("\(store.compression.groups.count) 组参数 · 每组都要写一次库")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help("不同比例 / 格式会分别跑一次，每次写库约 300 MB")
            }

            Spacer(minLength: 12)

            if selection.isEmpty {
                Button("清空压缩站") { store.compression.removeAll() }
                    .controlSize(.small)
                    .disabled(store.compression.isEmpty || store.conversionRunning)
                    .help("只是清掉待压缩名单，不动手机")

                Button {
                    Task { await store.runCompressionStation() }
                } label: {
                    if store.conversionRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("开始压缩 \(store.compression.count) 张",
                              systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.conversionRunning || store.compression.isEmpty)
                .help("整批只写一次相册库（约 300 MB）；原图会自动进回收站")
            } else {
                Text("已选 \(selection.count) 张 · \(AppStore.sizeText(selectedBytes))")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()

                Button("移除") {
                    store.compression.remove(ids: Array(selection))
                    selection = []
                }
                .controlSize(.small)
                .disabled(store.conversionRunning)
                .help("从压缩站移出这几张（不压缩）")

                Button {
                    Task { await store.runCompressionStation(ids: Array(selection)) }
                } label: {
                    Label("压缩选中 \(selection.count) 张",
                          systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.conversionRunning)
                .help("只压选中的这几张；整批只写一次相册库")

                Button("取消选择") { selection = [] }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background(.bar)
    }

    private var shownBytes: Int64 {
        shown.reduce(0) { $0 + $1.asset.byteSize }
    }

    private var selectedBytes: Int64 {
        shown.filter { selection.contains($0.id) }
            .reduce(0) { $0 + $1.asset.byteSize }
    }
}

private struct CompressionFrameReporter: View {
    let id: String

    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: CellFramePreference.self,
                value: [id: geo.frame(in: .named(MarqueeSpace.compression))]
            )
        }
    }
}
