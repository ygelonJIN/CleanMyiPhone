import SwiftUI

/// 压缩 / 转换：比例、格式、质量；批量选中时逐条显示会怎么变、哪些不支持。
struct ConversionSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var ratio: Double = 0.6
    @State private var format: ConversionProfile.Format = .heic
    @State private var quality: Double = 0.8

    private struct Selected: Identifiable {
        let asset: Asset
        let meta: PhotoLibraryIndex.Meta
        var id: Int { meta.pk }
    }

    private var selected: [Selected] {
        store.visibleAssets
            .filter { store.selection.contains($0.id) }
            .compactMap { asset in
                guard let meta = store.meta(asset) else { return nil }
                return Selected(asset: asset, meta: meta)
            }
    }

    private var photos: [Selected] { selected.filter { !$0.meta.isVideo } }
    private var videos: [Selected] { selected.filter { $0.meta.isVideo } }

    private var items: [ConversionItem] { photos.map { ConversionItem(meta: $0.meta) } }

    private var totalBefore: Int64 { photos.reduce(0) { $0 + $1.meta.byteSize } }
    private var totalAfter: Int64 { photos.reduce(0) { $0 + estimatedBytes($1.meta) } }

    private var ratioHint: String {
        guard let first = photos.first else { return "按每张图自己的尺寸缩" }
        let edge = max(first.meta.width, first.meta.height)
        let target = max(1, Int((Double(edge) * ratio).rounded()))
        return "当前 \(Int((ratio * 100).rounded()))%：长边 \(edge) → \(target) 像素"
    }

    private var qualityHint: String {
        "质量 \(Int((quality * 100).rounded()))：越高越清晰、文件越大；HEIC/JPEG 有效，PNG 无损忽略"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("压缩 / 转换")
                .font(.system(size: 15, weight: .semibold))

            if selected.isEmpty {
                Text("先在照片页选中照片，再打开这里")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(photos.count) 张照片 · \(size(totalBefore)) → \(size(totalAfter))（预计）")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !videos.isEmpty {
                    Text("\(videos.count) 个视频暂不支持，会跳过")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                }
                itemList
            }

            labeled("比例（按每张图自己的尺寸缩）") {
                HStack(spacing: 10) {
                    ProminentSlider(value: $ratio, range: 0.2...1.0, step: 0.05, tint: .green)
                    Text("\(Int((ratio * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 42, alignment: .trailing)
                }
            }
            Text("\(ratioHint) · 预计 \(size(totalAfter))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            labeled("格式") {
                Picker("", selection: $format) {
                    ForEach(ConversionProfile.Format.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            labeled("质量") {
                HStack(spacing: 10) {
                    ProminentSlider(value: $quality, range: 0.4...0.95, step: 0.05, tint: .teal)
                    Text("\(Int((quality * 100).rounded()))")
                        .font(.caption.monospacedDigit())
                        .frame(width: 30, alignment: .trailing)
                }
            }
            Text("\(qualityHint) · 预计 \(size(totalAfter))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            status

            HStack {
                Spacer()
                if store.conversionRunning {
                    Text("处理中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if store.conversionResult != nil {
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("取消") { dismiss() }
                    Button("开始转换") {
                        store.startConversion(
                            items: items,
                            profile: ConversionProfile(ratio: ratio, format: format, quality: quality))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(items.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { store.conversionResult = nil }
        .interactiveDismissDisabled(store.conversionRunning)
    }

    private var itemList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(photos.prefix(8)) { row($0) }
                if photos.count > 8 {
                    Text("还有 \(photos.count - 8) 张…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(videos.prefix(4)) { row($0) }
                if videos.count > 4 {
                    Text("还有 \(videos.count - 4) 个视频…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxHeight: 130)
    }

    @ViewBuilder
    private func row(_ selected: Selected) -> some View {
        HStack(spacing: 8) {
            Text(selected.meta.fileName)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 8)
            if selected.meta.isVideo {
                Text("视频不支持")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            } else {
                Text(describe(selected.meta))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func describe(_ meta: PhotoLibraryIndex.Meta) -> String {
        var parts: [String] = []
        parts.append("\(Int((ratio * 100).rounded()))%")
        parts.append("质量\(Int((quality * 100).rounded()))%")
        let from = formatName(meta.typeIdentifier, meta.fileName)
        if from != format.displayName {
            parts.append("\(from)→\(format.displayName)")
        }
        if meta.isLive { parts.append("去实况") }
        let before = size(meta.byteSize)
        let after = size(estimatedBytes(meta))
        parts.append("\(before)→\(after)")
        return parts.joined(separator: " · ")
    }

    private func estimatedBytes(_ meta: PhotoLibraryIndex.Meta) -> Int64 {
        let lower = meta.typeIdentifier.lowercased()
        let factor: Double
        switch format {
        case .heic:
            if lower.contains("png") { factor = 0.12 }
            else if lower.contains("raw") { factor = 0.10 }
            else if lower.contains("heic") || lower.contains("heif") { factor = 0.60 }
            else { factor = 0.50 }
        case .jpeg:
            if lower.contains("raw") { factor = 0.35 }
            else if lower.contains("heic") || lower.contains("heif") { factor = 1.10 }
            else { factor = 1.00 }
        case .png:
            factor = 1.60
        }
        let qualityFactor = format == .png ? 1.0 : max(0.35, min(1.5, quality / 0.8))
        return Int64(Double(meta.byteSize) * ratio * ratio * factor * qualityFactor)
    }

    private func formatName(_ uti: String, _ fileName: String) -> String {
        let lower = uti.lowercased()
        if lower.contains("heic") || lower.contains("heif") { return "HEIC" }
        if lower.contains("jpeg") { return "JPEG" }
        if lower.contains("png") { return "PNG" }
        if lower.contains("raw") { return "RAW" }
        return (fileName as NSString).pathExtension.uppercased()
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @ViewBuilder
    private var status: some View {
        if store.conversionRunning, let progress = store.conversionProgress {
            VStack(alignment: .leading, spacing: 6) {
                if progress.phase == "改库" || progress.phase == "重启相册" {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(progress.phase == "改库"
                             ? "正在写库（约 300 MB），这一步会停一会儿…"
                             : "正在让相册重新读库（不重启手机）…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView(value: progress.total > 0
                                 ? Double(progress.completed) / Double(progress.total) : 0)
                    Text("\(progress.phase) \(progress.completed)/\(progress.total) \(progress.current)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else if let result = store.conversionResult {
            VStack(alignment: .leading, spacing: 6) {
                if result.records.isEmpty {
                    Label("没有成功的项", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("完成 \(result.records.count) 张")
                                .font(.callout.weight(.semibold))
                            let saved = savedBytes(result)
                            if saved > 0 {
                                Text("节省 \(size(saved))")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else if saved < 0 {
                                Text("体积增加 \(size(-saved))（格式转换可能变大）")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                ForEach(Array(result.failures.prefix(6).enumerated()), id: \.offset) { _, failure in
                    Text("\(failure.name)：\(failure.reason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if result.daemonRestarted {
                    Text("相册已刷新")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func savedBytes(_ result: PhotoConversionEngine.Result) -> Int64 {
        let success = Set(result.records.map(\.originalPK))
        let before = photos.filter { success.contains($0.meta.pk) }
            .reduce(Int64(0)) { $0 + $1.meta.byteSize }
        let after = result.records.reduce(Int64(0)) { $0 + $1.newSize }
        return before - after
    }

    private func labeled<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// 比系统 Slider 更显眼的滑杆：粗轨道、已选部分填色、大圆点、位置一眼可见。
private struct ProminentSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var tint: Color = .green

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let fraction = min(1, max(0, (value - range.lowerBound)
                                 / (range.upperBound - range.lowerBound)))
            let knob: CGFloat = 24
            let fillWidth = max(10, width * fraction)
            let offset = min(width - knob, max(0, width * fraction - knob / 2))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 10)
                Capsule()
                    .fill(tint)
                    .frame(width: fillWidth, height: 10)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .overlay(Circle().strokeBorder(tint, lineWidth: 3))
                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                    .offset(x: offset)
            }
            .frame(height: knob)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { gesture in
                    let f = min(1, max(0, gesture.location.x / width))
                    let raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
                    let stepped = (raw / step).rounded() * step
                    value = min(range.upperBound, max(range.lowerBound, stepped))
                }
            )
        }
        .frame(height: 26)
    }
}
