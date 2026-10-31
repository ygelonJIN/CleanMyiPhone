import SwiftUI

/// 环形图：自绘圆弧，支持悬停高亮与入场动画
struct DonutChart: View {
    struct Slice: Identifiable {
        let id = UUID()
        let title: String
        let bytes: Int64
        let color: Color
    }

    let slices: [Slice]
    var size: CGFloat = 132
    var centerTitle: String?
    var centerDetail: String?
    var lineWidth: CGFloat = 18
    var highlightTitle: String?
    var onHoverTitle: ((String?) -> Void)?
    var onHoverIndex: ((Int?) -> Void)?

    @State private var hovered: Int?
    @State private var progress: CGFloat = 0

    private var total: Int64 { max(slices.reduce(0) { $0 + $1.bytes }, 1) }

    private func fraction(_ index: Int) -> CGFloat {
        CGFloat(Double(slices[index].bytes) / Double(total))
    }

    private func startFraction(_ index: Int) -> CGFloat {
        slices[0..<index].indices.reduce(CGFloat(0)) { $0 + fraction($1) }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.12), lineWidth: lineWidth)

            ForEach(Array(slices.enumerated()), id: \.offset) { index, slice in
                let start = startFraction(index)
                let width = fraction(index)
                let gap: CGFloat = slices.count > 1 ? 0.0045 : 0
                let from = start + gap / 2
                let to = start + width - gap / 2
                let isExternalHighlight = highlightTitle != nil && highlightTitle == slice.title
                Circle()
                    .trim(from: from, to: max(from, from + (to - from) * progress))
                    .stroke(slice.color,
                            style: StrokeStyle(lineWidth: (hovered == index || isExternalHighlight) ? lineWidth + 3 : lineWidth,
                                               lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .opacity(highlightTitle == nil ? (hovered == nil || hovered == index ? 1 : 0.32)
                                                   : (isExternalHighlight ? 1 : 0.28))
                    .animation(.easeOut(duration: 0.16), value: hovered)
            }

            VStack(spacing: 1) {
                Text(centerTitle ?? ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                    .font(.system(size: size * 0.17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let centerDetail {
                    Text(centerDetail)
                        .font(.system(size: max(10, size * 0.062)))
                        .foregroundStyle(.secondary)
                }
            }
            .scaleEffect(progress < 0.5 ? 0.94 : 1)
            .opacity(Double(progress))
        }
        .frame(width: size, height: size)
        // 命中区就是环带本身：环内空洞、圆外都不响应，指针「出了那块蓝色就不变」
        .contentShape(RingShape(inset: lineWidth))
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let index = sliceIndex(at: point)
                if hovered != index { hovered = index }
                if let index {
                    onHoverTitle?(slices[index].title)
                } else {
                    onHoverTitle?(nil)
                }
                onHoverIndex?(index)
            case .ended:
                hovered = nil
                onHoverTitle?(nil)
                onHoverIndex?(nil)
            }
        }
        .opacity(1)
        .onAppear {
            guard progress == 0 else { return }
            withAnimation(.easeOut(duration: 0.7)) { progress = 1 }
        }
    }

    /// 只有指针真的落在环带、并且落在某一段的弧上才算悬停。
    /// 圆环内侧、段与段之间的缝隙、圆外都不算。
    private func sliceIndex(at point: CGPoint) -> Int? {
        let center = CGPoint(x: size / 2, y: size / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        let outer = size / 2
        let inner = max(0, outer - lineWidth - 1)
        guard distance <= outer + 1, distance >= inner else { return nil }

        var angle = atan2(dy, dx) * 180 / .pi + 90
        if angle < 0 { angle += 360 }
        let target = CGFloat(angle) / 360

        let gap: CGFloat = slices.count > 1 ? 0.0045 : 0
        var cursor: CGFloat = 0
        for (index, _) in slices.enumerated() {
            let width = fraction(index)
            let from = cursor + gap / 2
            let to = cursor + width - gap / 2
            if target >= from && target <= to { return index }
            cursor += width
        }
        return nil
    }

    /// 第 index 段弧中点（角度制，0° 在 12 点，顺时针）
    func midAngleDegrees(index: Int) -> Double {
        guard index >= 0, index < slices.count else { return 0 }
        var cursor: Double = 0
        for i in 0..<index { cursor += Double(fraction(i)) }
        return (cursor + Double(fraction(index)) / 2) * 360
    }

    var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                LegendRow(slice: slice, percent: percent(slice.bytes))
            }
        }
    }

    private func percent(_ bytes: Int64) -> String {
        String(format: "%.0f%%", Double(bytes) / Double(total) * 100)
    }
}

/// 图例行：悬停高亮
struct LegendRow: View {
    let slice: DonutChart.Slice
    let percent: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(slice.color)
                .frame(width: hovering ? 9 : 8, height: hovering ? 9 : 8)
            Text(slice.title)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 10)
            Text(ByteCountFormatter.string(fromByteCount: slice.bytes, countStyle: .file))
                .font(.callout.monospacedDigit())
                .foregroundStyle(hovering ? .primary : .secondary)
            Text(percent)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.secondary.opacity(0.10) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// 横向条形（重叠维度）
struct BarRow: View {
    let title: String
    let detail: String
    let ratio: Double
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .frame(width: 62, alignment: .leading)
                .lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.10))
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, proxy.size.width * min(max(ratio, 0), 1)))
                }
            }
            .frame(height: 8)
            Text(detail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
        }
    }
}

/// 统计面板卡片
struct StatsPanel<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.background.secondary)
        )
    }
}

/// 载入占位：骨架 + 呼吸动画
struct LoadingCard: View {
    var height: CGFloat = 220
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(.background.secondary)
            .frame(height: height)
            .overlay {
                HStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("正在读取 iPhone…").font(.callout.weight(.medium))
                        Text("照片清单与存储信息").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .opacity(pulse ? 0.72 : 1)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

// MARK: - 统一的数据片

/// 概览、应用页、图表条共用的一种「片」：有体积、有颜色、可选个数。
/// 和 `DonutChart.Slice` 的区别是它没有 UUID，值不变就不会重画。
struct ChartSlice: Identifiable, Hashable {
    var id: String { title }
    let title: String
    let bytes: Int64
    let color: Color
    var count: Int?

    var percent: Double {
        // 单片的百分比要对照它所在的那张图，调用方自己算
        0
    }
}

extension DonutChart.Slice {
    init(_ item: ChartSlice) {
        self.init(title: item.title, bytes: item.bytes, color: item.color)
    }
}

// MARK: - 小饼图（概览 / 应用页的图表条）

/// 92pt 的小环：不占卡片、不带图例、中心显示最大一片的占比。
/// 一行放不下就横向滑（见 `ChartStrip`）。
struct MiniDonut: View {
    let title: String
    let slices: [ChartSlice]
    var size: CGFloat = 92
    var lineWidth: CGFloat = 11
    var onHover: ((String?) -> Void)?

    @State private var hovered: String?

    private var total: Int64 { max(slices.reduce(0) { $0 + $1.bytes }, 1) }

    /// 中心显示「第一片」的占比：调用方把要强调的那一片放在第一位
    /// （已隐藏 / 收藏 / 最近删除 / 某个相簿），这样不会被「其他」抢走。
    private var subject: ChartSlice? { slices.first }

    private var centerText: String {
        guard let subject else { return "—" }
        let value = Double(subject.bytes) / Double(total) * 100
        if value > 0, value < 1 { return "<1%" }
        return String(format: "%.0f%%", value)
    }

    private var subtitle: String { subject?.title ?? "" }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.10), lineWidth: lineWidth)

                ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                    let start = startFraction(index)
                    let width = Double(slice.bytes) / Double(total)
                    let gap: Double = slices.count > 1 ? 0.006 : 0
                    let from = start + gap / 2
                    let to = start + width - gap / 2
                    Circle()
                        .trim(from: from, to: max(from, to))
                        .stroke(slice.color,
                                style: StrokeStyle(lineWidth: hovered == slice.title ? lineWidth + 2.5 : lineWidth,
                                                   lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                        .opacity(hovered == nil || hovered == slice.title ? 1 : 0.35)
                        .animation(.easeOut(duration: 0.14), value: hovered)
                }

                VStack(spacing: 0) {
                    Text(centerText)
                        .font(.system(size: size * 0.20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if size >= 84, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: max(8, size * 0.10)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: size, height: size)
            .contentShape(RingShape(inset: CGFloat(lineWidth)))

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: size + 16)
        }
        .frame(width: size + 22)
        .help(helpText)
        .onHover { inside in
            if !inside { hovered = nil; onHover?(nil) }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let hit = slice(at: point)
                if hit != hovered {
                    hovered = hit
                    onHover?(hit)
                }
            case .ended:
                hovered = nil
                onHover?(nil)
            }
        }
    }

    private var helpText: String {
        slices.map { item in
            let value = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
            var line = "\(item.title) \(value)"
            if let count = item.count { line += " · \(count) 项" }
            return line
        }.joined(separator: "\n")
    }

    private func startFraction(_ index: Int) -> Double {
        slices[0..<index].reduce(0) { $0 + Double($1.bytes) / Double(total) }
    }

    /// 命中判定：必须落在环带上，且角度落在某一段的弧内
    private func slice(at point: CGPoint) -> String? {
        let center = CGPoint(x: size / 2, y: size / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        let outer = size / 2
        let inner = max(0, outer - lineWidth - 1)
        guard distance <= outer + 1, distance >= inner else { return nil }

        var angle = atan2(dy, dx) * 180 / .pi + 90
        if angle < 0 { angle += 360 }
        let target = angle / 360

        var cursor = 0.0
        for slice in slices {
            let width = Double(slice.bytes) / Double(total)
            let gap: Double = slices.count > 1 ? 0.006 : 0
            let from = cursor + gap / 2
            let to = cursor + width - gap / 2
            if target >= from, target <= to { return slice.title }
            cursor += width
        }
        return nil
    }
}

/// 环形命中区：外圆顺时针、内圆逆时针各画一圈，中间自然挖空。
/// 这样指针在环内空洞里、在圆外都不会触发悬停。
struct RingShape: Shape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = max(0, outer - inset)
        var path = Path()
        path.addArc(center: center, radius: outer,
                    startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
        if inner > 0 {
            path.addArc(center: center, radius: inner,
                        startAngle: .degrees(0), endAngle: .degrees(360), clockwise: true)
        }
        path.closeSubpath()
        return path
    }
}

/// 一排小饼图：放不下就横向滑
struct ChartStrip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 6) {
                content
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - 实心饼图（概览用）

/// 实心扇形饼图。不带文字、不带图例，标注交给外面画折线。
struct SolidPie: View {
    let slices: [ChartSlice]
    var size: CGFloat = 240
    var highlight: String?
    var onHover: ((String?) -> Void)?

    private var total: Int64 { max(slices.reduce(0) { $0 + $1.bytes }, 1) }

    var body: some View {
        ZStack {
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                let start = startFraction(index)
                let width = Double(slice.bytes) / Double(total)
                let gap: Double = slices.count > 1 ? 0.0035 : 0
                PieWedge(start: start + gap / 2, end: start + width - gap / 2)
                    .fill(slice.color)
                    .overlay {
                        PieWedge(start: start + gap / 2, end: start + width - gap / 2)
                            .fill(.white.opacity(highlight == slice.title ? 0.16 : 0))
                    }
                    .opacity(highlight == nil || highlight == slice.title ? 1 : 0.45)
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(-90))
        .contentShape(Circle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                onHover?(sliceTitle(at: point))
            case .ended:
                onHover?(nil)
            }
        }
    }

    private func startFraction(_ index: Int) -> Double {
        slices[0..<index].reduce(0) { $0 + Double($1.bytes) / Double(total) }
    }

    /// 命中判定按扇形角度算，圆心附近不响应
    private func sliceTitle(at point: CGPoint) -> String? {
        let center = CGPoint(x: size / 2, y: size / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard sqrt(dx * dx + dy * dy) <= size / 2 else { return nil }
        var angle = atan2(dy, dx) * 180 / .pi + 90
        if angle < 0 { angle += 360 }
        let target = angle / 360
        var cursor = 0.0
        for slice in slices {
            let width = Double(slice.bytes) / Double(total)
            if target >= cursor, target <= cursor + width { return slice.title }
            cursor += width
        }
        return nil
    }
}

/// 一块扇形（0 在 12 点、顺时针）
struct PieWedge: Shape {
    var start: Double   // 0–1
    var end: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: center)
        path.addArc(center: center,
                    radius: radius,
                    startAngle: .degrees(start * 360),
                    endAngle: .degrees(end * 360),
                    clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// 饼图 + 周围折线标注：卡片贴着每一片放，用该片自己的颜色折线连过去。
/// 几何是算出来的，不用 PreferenceKey 收集，窗口拉伸时不会抖。
struct PieWithCallouts: View {
    let slices: [ChartSlice]
    var pieSize: CGFloat = 240
    var cardWidth: CGFloat = 132
    var cardHeight: CGFloat = 42
    var gap: CGFloat = 26
    var highlight: String?
    var onHover: ((String?) -> Void)?

    private var total: Int64 { max(slices.reduce(0) { $0 + $1.bytes }, 1) }

    private var layout: (width: CGFloat, height: CGFloat) {
        let width = pieSize + 2 * (cardWidth + gap)
        // 上下各留出折线的拐弯空间，否则顶上的那一片线会画到框外
        let cardStack = CGFloat(slices.count) * (cardHeight + 6) + 16
        let height = max(pieSize + 40, cardStack)
        return (width, height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SolidPie(slices: slices, size: pieSize, highlight: highlight, onHover: onHover)
                .position(x: layout.width / 2, y: layout.height / 2)

            ForEach(Array(placements.enumerated()), id: \.element.id) { _, item in
                calloutLine(item)
                calloutCard(item)
            }
        }
        .frame(width: layout.width, height: layout.height)
    }

    private struct Placement: Identifiable {
        var id: String { slice.title }
        let slice: ChartSlice
        let side: Int          // -1 左，1 右
        let cardCenter: CGPoint
        let anchor: CGPoint    // 饼边上的点
        let elbow: CGPoint     // 折点
    }

    private var placements: [Placement] {
        let center = CGPoint(x: layout.width / 2, y: layout.height / 2)
        let radius = pieSize / 2
        var items: [(slice: ChartSlice, side: Int, angle: Double)] = []
        var cursor = 0.0
        for slice in slices {
            let width = Double(slice.bytes) / Double(total)
            let mid = (cursor + width / 2) * 360
            cursor += width
            let radians = mid * .pi / 180
            let dx = sin(radians)
            items.append((slice, dx >= 0 ? 1 : -1, mid))
        }

        var result: [Placement] = []
        for side in [-1, 1] {
            let column = items.filter { $0.side == side }
            guard !column.isEmpty else { continue }
            let cardX = side > 0
                ? center.x + radius + gap + cardWidth / 2
                : center.x - radius - gap - cardWidth / 2
            // 期望位置按角度算，然后做一次去重叠
            var ys = column.map { item -> CGFloat in
                let radians = item.angle * .pi / 180
                let y = center.y - cos(radians) * (radius + 24)
                return min(max(y, cardHeight / 2 + 2), layout.height - cardHeight / 2 - 2)
            }
            let step = cardHeight + 6
            for index in ys.indices {
                if index > 0, ys[index] < ys[index - 1] + step { ys[index] = ys[index - 1] + step }
            }
            // 越过下界的往上推
            var overflow = ys.last.map { $0 - (layout.height - cardHeight / 2 - 2) } ?? 0
            if overflow > 0 {
                for index in ys.indices.reversed() {
                    let limit = index == ys.count - 1
                        ? layout.height - cardHeight / 2 - 2
                        : ys[index + 1] - step
                    ys[index] = min(ys[index], limit)
                }
                overflow = 0
                _ = overflow
            }

            for (index, item) in column.enumerated() {
                let radians = item.angle * .pi / 180
                let anchor = CGPoint(x: center.x + sin(radians) * radius,
                                     y: center.y - cos(radians) * radius)
                // 拐点压在框内，别让最上/最下那一片的线跑到画面外
                let rawElbowY = center.y - cos(radians) * (radius + 18)
                let elbow = CGPoint(x: center.x + sin(radians) * (radius + 18),
                                    y: min(max(rawElbowY, 6), layout.height - 6))
                let cardCenter = CGPoint(x: cardX, y: ys[index])
                result.append(Placement(slice: item.slice, side: side,
                                        cardCenter: cardCenter, anchor: anchor, elbow: elbow))
            }
        }
        return result
    }

    private func calloutLine(_ item: Placement) -> some View {
        let edgeX = item.cardCenter.x - CGFloat(item.side) * (cardWidth / 2 + 4)
        let path = Path { path in
            path.move(to: item.anchor)
            path.addLine(to: item.elbow)
            path.addLine(to: CGPoint(x: edgeX, y: item.elbow.y))
            if abs(item.cardCenter.y - item.elbow.y) > 0.5 {
                path.addLine(to: CGPoint(x: edgeX, y: item.cardCenter.y))
            }
        }
        let active = highlight == nil || highlight == item.slice.title
        return path
            .stroke(item.slice.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .opacity(active ? 0.95 : 0.25)
            .allowsHitTesting(false)
    }

    private func calloutCard(_ item: Placement) -> some View {
        let value = ByteCountFormatter.string(fromByteCount: item.slice.bytes, countStyle: .file)
        let percent = String(format: "%.0f%%", Double(item.slice.bytes) / Double(total) * 100)
        return VStack(alignment: .leading, spacing: 1) {
            Text(item.slice.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 5) {
                Text(value)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(percent)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: cardWidth, height: cardHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(item.slice.color.opacity(0.55), lineWidth: 1)
        )
        .overlay(alignment: item.side > 0 ? .leading : .trailing) {
            Rectangle()
                .fill(item.slice.color)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .position(item.cardCenter)
        .onHover { inside in onHover?(inside ? item.slice.title : nil) }
    }
}

/// 小饼图 + 旁边一列图例（色块 + 名称 + 占比）
struct PieWithLegend: View {
    let title: String
    let slices: [ChartSlice]
    var size: CGFloat = 104
    var note: String?

    private var total: Int64 { max(slices.reduce(0) { $0 + $1.bytes }, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            HStack(alignment: .center, spacing: 12) {
                SolidPie(slices: slices, size: size)

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(slices) { slice in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(slice.color)
                                .frame(width: 9, height: 9)
                            Text(slice.title)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(String(format: "%.0f%%", Double(slice.bytes) / Double(total) * 100))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
