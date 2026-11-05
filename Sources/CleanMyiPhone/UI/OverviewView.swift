import SwiftUI

/// 概览：不放饼图。用一条占比条 + 卡片 + 两个排行把「哪块最占地方」说清楚。
struct OverviewView: View {
    @Environment(AppStore.self) private var store

    /// 内容区实际宽度：卡片列数按它算，保证每张卡都有最小宽度，挤不扁
    @State private var contentWidth: CGFloat = 0
    /// 兜底：数据要是永远到不了（设备不回容量），不能一直透明晾着
    @State private var forceRevealed = false


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 概览**没有顶栏**（用户定的）：刷新入口在左下角侧栏那两颗按钮里，
            // 页面上不再放一颗「重新读取」，省掉一整条空栏。
            Group {
                if store.needsConnection {
                    // 空态**必须在内容区正中**，不能塞进 ScrollView 顶部（2026-11 用户报的）
                    emptyConnect
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if !store.hasStats {
                                // 全屏遮罩盖在上面了，这里不重复放转圈
                                Color.clear.frame(height: 240)
                            } else {
                                usageBlock
                                cardGrid
                                // 并排时每块的横条会被压到只剩几像素（"挤成一团"就是这么来的）。
                                // 宽度不够就改成上下排，横条才有地方长。
                                if contentWidth >= 620 {
                                    HStack(alignment: .top, spacing: 20) {
                                        photoTypeBlock
                                        albumBlock
                                    }
                                } else {
                                    VStack(spacing: 20) {
                                        photoTypeBlock
                                        albumBlock
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 和照片页**同一套**：整块淡入 + 从 0.985 微缩，0.85 秒（`Motion.page`）。
            // 只在外层做一次 —— 卡片、占比条、两个排行都不各自动，
            // 不做错峰、不做数字跳变，眼感和照片页换页完全一致。
            //
            // 关键是 `blocked`：启动时先别露（一直全透明），等门禁撤了、数据到了
            // 再播。之前靠"改 key 重播"，但那时遮罩正盖着、动画在底下就播完了，
            // 所以启动进概览永远看不到。
            .pageReveal(store.pageKey, blocked: revealBlocked)

            Divider()
            bottomBar
        }
        .onAppear {
            // 最坏情况：6 秒还没等到数据就别再藏着了
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if !forceRevealed { forceRevealed = true }
            }
        }
    }

    /// 何时才允许概览内容露出来。
    /// 空态（没连设备）要立刻显示，其余一律等「门禁撤了 + 首批数据到了」——
    /// 那一刻才播淡入，用户第一次看到概览就带着动画。
    private var revealBlocked: Bool {
        if store.needsConnection || forceRevealed { return false }
        // 模拟设备没有真实容量，别让它一直卡着
        if store.usingFixture { return store.needsLibraryGate }
        return store.needsLibraryGate || !store.hasStats
    }

    /// 底栏：原来顶栏副标题上的「设备名 / 正在读取 / 已锁屏」搬到这里。
    /// 顶栏既然不放标题，状态就该有个固定的家 —— 和照片页、回收站的底栏同高 38pt。
    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text(deviceLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if store.isScanning, !store.needsConnection {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(store.scanStageTitle)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if store.deviceCapacity > 0 {
                Text("共 \(AppStore.sizeText(store.deviceCapacity))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        // 必须显式撑满：外层是 `VStack(alignment: .leading)`，
        // 不给 maxWidth 的话底栏宽度只到最后一个字，右边会露出窗口背景
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 38)
        .background(.bar)
        .animation(Motion.fade, value: store.isScanning)
    }

    private var deviceLine: String {
        if store.needsConnection { return "未连接 iPhone" }
        if store.isDeviceLocked { return "设备已锁屏" }
        return store.stats.deviceName.isEmpty ? "未连接" : store.stats.deviceName
    }

    // MARK: - 容量总览

    private var usageBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(AppStore.sizeText(store.usedBytes))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("已用 · 共 \(AppStore.sizeText(store.deviceCapacity))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.usedPercent)%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            StackedBar(segments: barSegments, height: 20)

            HStack(spacing: 14) {
                ForEach(Array(barSegments.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(item.color)
                            .frame(width: 9, height: 9)
                        Text(item.label)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Text(AppStore.sizeText(Int64(item.value)))
                            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var barSegments: [StackedBar.Segment] {
        var list: [StackedBar.Segment] = []
        // 库索引没就绪时，媒体两段和应用与数据都是猜的（视频偏小、应用与数据虚高），
        // 干脆不画，只留系统 / 回收站 / 可用这些设备自己报的实数。
        if store.mediaBytesReady {
            if store.mediaPhotoBytes > 0 {
                list.append(.init(label: "照片", value: Double(store.mediaPhotoBytes), color: Theme.photo))
            }
            if store.mediaVideoBytes > 0 {
                list.append(.init(label: "视频", value: Double(store.mediaVideoBytes), color: Theme.video))
            }
            if store.appsBytes > 0 {
                list.append(.init(label: "应用与数据", value: Double(store.appsBytes), color: Theme.app))
            }
        }
        if store.systemBytes > 0 {
            list.append(.init(label: "系统", value: Double(store.systemBytes), color: Theme.system))
        }
        if store.trash.totalBytes > 0 {
            list.append(.init(label: "回收站", value: Double(store.trash.totalBytes), color: .orange))
        }
        list.append(.init(label: "可用", value: Double(store.freeBytes), color: Theme.other))
        return list
    }

    /// 库索引没就绪时的占位：不给数字，也不给「0 项」这种同样是骗人的读数
    private var mediaPending: String { "读取中…" }

    // MARK: - 卡片

    /// 卡片网格的列：**每张卡至少 168pt**，放不下 3 列就退成 2 列。
    /// 最小窗口（内容区约 466pt）下 3 列只有 146pt/张，字会被压 —— 宁可两列。
    private var cardColumns: [GridItem] {
        let spacing = 14.0
        let minCard = 168.0
        let cols: Int
        if contentWidth <= 0 {
            cols = 3                                  // 首帧还不知道宽度，先按 3 列
        } else {
            cols = min(3, max(1, Int((contentWidth - spacing) / (minCard + spacing))))
        }
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: cols)
    }

    private var cardGrid: some View {
        LazyVGrid(columns: cardColumns, spacing: 14) {
            StatCard(title: "照片",
                     value: store.mediaBytesReady ? AppStore.sizeText(store.mediaPhotoBytes) : mediaPending,
                     detail: store.mediaBytesReady ? "\(store.libraryPhotoCount) 项" : "等相册索引",
                     color: Theme.photo)
            StatCard(title: "视频",
                     value: store.mediaBytesReady ? AppStore.sizeText(store.mediaVideoBytes) : mediaPending,
                     detail: store.mediaBytesReady ? "\(store.libraryVideoCount) 项" : "等相册索引",
                     color: Theme.video)
            StatCard(title: "应用与数据",
                     value: store.mediaBytesReady ? AppStore.sizeText(store.appsBytes) : mediaPending,
                     detail: store.mediaBytesReady
                        ? "\(store.userAppCount) 个 App + 文稿 + 系统数据 + 缓存"
                        : "等相册索引",
                     color: Theme.app)
            StatCard(title: "系统", value: AppStore.sizeText(store.systemBytes),
                     detail: "iOS 本体（系统分区）", color: Theme.system)
            StatCard(title: "可用", value: AppStore.sizeText(store.freeBytes),
                     detail: "共 \(AppStore.sizeText(store.deviceCapacity))", color: Theme.other)
            StatCard(title: "回收站", value: AppStore.sizeText(store.trash.totalBytes),
                     detail: "\(store.trash.count) 项 · 清空才真删", color: .orange)
        }
        .background {
            // 只量宽度，不参与布局
            GeometryReader { proxy in
                Color.clear
                    .onAppear { contentWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in
                        // 不在 view update 期间直接改状态，等下一帧
                        DispatchQueue.main.async { contentWidth = width }
                    }
            }
        }
    }

    // MARK: - 照片类型（和侧栏同一套分类，按体积从高到低）

    private var photoTypeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("照片类型")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(store.typeRanking.count) 类")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if store.typeRanking.isEmpty {
                Text(store.metricsReady ? "相册库里没有可统计的项" : "正在读取相册库…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                // 和「相簿大小」完全一样的读法：名字 / 项数 / 长度条 / 体积，按体积降序
                let maxBytes = store.typeRanking.first?.bytes ?? 1
                ForEach(Array(store.typeRanking.enumerated()), id: \.offset) { _, item in
                    // 排版按用户定的：**名称 → 条 → 项数 → 体积**。
                    // 条紧贴名称右侧、尽量长；项数紧贴体积左边。
                    HStack(spacing: 6) {
                        Label(item.filter.title, systemImage: item.filter.symbol)
                            .labelStyle(.titleAndIcon)
                            .font(.callout)
                            .lineLimit(1)
                            .frame(width: 82, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.10))
                                Capsule().fill(Theme.album)
                                    .frame(width: max(3, proxy.size.width * Double(item.bytes) / Double(max(maxBytes, 1))))
                            }
                        }
                        .frame(height: 8)
                        Text("\(item.count.formatted()) 项")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 48, alignment: .trailing)
                        Text(AppStore.sizeText(item.bytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                    .help(item.filter.help)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: - 相簿排行

    private var albumBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("相簿大小")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(store.albumRanking.count) 本")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if store.albumRanking.isEmpty {
                Text("还没有读到相簿")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                let maxBytes = store.albumRanking.first?.bytes ?? 1
                ForEach(Array(store.albumRanking.prefix(12)), id: \.album.id) { item in
                    HStack(spacing: 6) {
                        Text(item.album.title)
                            .font(.callout)
                            .lineLimit(1)
                            .frame(width: 82, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.10))
                                Capsule().fill(Theme.album)
                                    .frame(width: max(3, proxy.size.width * Double(item.bytes) / Double(max(maxBytes, 1))))
                            }
                        }
                        .frame(height: 8)
                        Text("\(item.album.count) 张")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 48, alignment: .trailing)
                        Text(AppStore.sizeText(item.bytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.background.secondary))
    }

    // MARK: - 空态

    private var emptyConnect: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("没有检测到 iPhone").font(.callout.weight(.medium))
            Text("用数据线连上手机，解锁后点「信任」")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("重新检测") { store.connectRealDevice() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
