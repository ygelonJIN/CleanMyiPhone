import SwiftUI

/// 概览：不放饼图。用一条占比条 + 卡片 + 两个排行把「哪块最占地方」说清楚。
struct OverviewView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(title: "概览", subtitle: subtitle) {
                Button {
                    Task { await store.startScan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新读取设备")
                .disabled(store.isScanning)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.needsConnection {
                        emptyConnect
                    } else if !store.hasStats {
                        // 全屏加载盖在上面了，这里不重复放转圈
                        Color.clear.frame(height: 240)
                    } else {
                        usageBlock
                        cardGrid
                        HStack(alignment: .top, spacing: 18) {
                            photoTypeBlock
                            albumBlock
                        }
                    }
                    footnote
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 20)
            }
        }
    }

    private var subtitle: String {
        if store.needsConnection { return "未连接 iPhone" }
        if store.isDeviceLocked { return "设备已锁屏" }
        if store.isScanning, let bytes = store.libraryByteText {
            return "正在读取相册索引 \(bytes)"
        }
        if store.isScanning { return "正在读取…" }
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
                            .foregroundStyle(.primary)
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

    private var cardGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
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
    }

    // MARK: - 照片类型

    private var photoTypeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("照片类型")
                .font(.subheadline.weight(.semibold))
            Text("三类互不重叠：照片（不含截屏）、截屏（subtype 10）、视频。已隐藏与最近删除已经算在下面的照片与视频里（隐藏 \(store.hiddenStats.count) 项 · \(AppStore.sizeText(store.hiddenStats.bytes))）。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(store.photoKindRows, id: \.title) { row in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(row.color)
                        .frame(width: 9, height: 9)
                    Text(row.title)
                        .font(.callout)
                    Text("\(row.count) 项")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    Text(AppStore.sizeText(row.bytes))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", row.percent))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 40, alignment: .trailing)
                }
                .padding(.vertical, 1)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.10))
                        Capsule().fill(row.color)
                            .frame(width: max(3, proxy.size.width * row.percent / 100))
                    }
                }
                .frame(height: 6)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.background.secondary))
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
                    HStack(spacing: 8) {
                        Text(item.album.title)
                            .font(.callout)
                            .lineLimit(1)
                            .frame(width: 88, alignment: .leading)
                        Text("\(item.album.count) 张")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 50, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.10))
                                Capsule().fill(Theme.album)
                                    .frame(width: max(3, proxy.size.width * Double(item.bytes) / Double(max(maxBytes, 1))))
                            }
                        }
                        .frame(height: 7)
                        Text(AppStore.sizeText(item.bytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                    .padding(.vertical, 1)
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var footnote: some View {
        Text("照片与视频按相册库的资源表统计（原图 + 编辑渲染版本 + Live Photo 视频分量）；系统 = 系统分区（7.93 GB）；「应用与数据」= 已用 − 媒体 − 系统 − 回收站，包含 App 本体、App 的文稿与数据、系统数据、各类缓存与日志。手机设置把这四项分开显示，iOS 不向第三方提供分项。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
