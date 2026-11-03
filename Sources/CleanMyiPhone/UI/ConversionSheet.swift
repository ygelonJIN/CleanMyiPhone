import SwiftUI

/// 压缩 / 转换：比例、格式、质量；批量选中时逐条显示会怎么变、哪些不支持。
struct ConversionSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var ratio: Double
    @State private var format: ConversionProfile.Format
    @State private var quality: Double

    /// 每次被构造（= 每次打开面板）都从盘上取上次那套。
    ///
    /// ⚠️ **不要写成 `private static let saved = CompressionPrefs.load()` 再给三个 `@State` 赋初值**：
    /// `static let` 在进程内只求值一次，于是「改成 40% → 关掉面板 → 再打开」拿到的还是
    /// 进程启动时读到的那份（默认 60%/Q80），看着就是「比例和质量记不住」（2026-11 用户报的）。
    /// 只有退出重启才会看起来正常 —— 那正好骗过自己。
    init() {
        let saved = CompressionPrefs.load()
        _ratio = State(initialValue: saved.ratio)
        _format = State(initialValue: saved.format)
        _quality = State(initialValue: saved.quality)
    }

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
    /// 选中里已经在压缩站排队的张数（再标就是改参数）
    private var queuedCount: Int {
        photos.filter { store.isQueuedForCompression($0.asset.id) }.count
    }
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

            if queuedCount > 0 {
                Text("其中 \(queuedCount) 张已经在压缩站里：再标一次就是改参数")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            // 这里**只标记**，所以不再放「写回手机相册」开关（那是执行时的事，在压缩站里）
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "bookmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("点「标记压缩」只是记下来（不动手机、不改库）。攒够一批后到左侧「压缩站」二次确认，才真的压缩 —— 整批只写一次相册库（约 300 MB）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                    Button("标记压缩") {
                        // 先落盘参数：用户在面板里调过什么，下次打开就得是这个
                        store.markForCompression(profile: currentPrefs.profile)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(items.isEmpty)
                    .help("只标记，不动手机；到「压缩站」确认后才真的压")
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { store.conversionResult = nil }
        // 拖一下滑块、换个格式就立刻记住（不等点「标记压缩」）：
        // 用户说过「每次新设置的都记住保留」，中途关掉面板也算设置过。
        .onChange(of: ratio) { _, _ in savePrefs() }
        .onChange(of: format) { _, _ in savePrefs() }
        .onChange(of: quality) { _, _ in savePrefs() }
        .interactiveDismissDisabled(store.conversionRunning)
    }

    /// 面板当前的三个参数（存盘、标记、估算都用它，别各拼一份）
    private var currentPrefs: CompressionPrefs {
        CompressionPrefs(ratio: ratio, format: format, quality: quality, stripLive: true)
    }

    private func savePrefs() {
        currentPrefs.save()
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

    /// 当前面板参数。估算走 `ConversionProfile.estimatedBytes(for:)`，
    /// 和底栏、压缩站用**同一份系数**（分开写会给出两个不同的「预计」）。
    private var profile: ConversionProfile { currentPrefs.profile }

    private func estimatedBytes(_ meta: PhotoLibraryIndex.Meta) -> Int64 {
        profile.estimatedBytes(for: meta)
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
                            // 三段分开报，别把「原图还在」混成「压缩后变大了」：
                            // 副本合计、原图合计（已标记到回收站）、彻底删除后的净省。
                            let copyBytes = result.records.reduce(Int64(0)) { $0 + $1.newSize }
                            let originalBytes = result.records.reduce(Int64(0)) { $0 + $1.originalSize }
                            let net = originalBytes - copyBytes
                            Text("副本合计 \(size(copyBytes))（原图 \(size(originalBytes))）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if net > 0 {
                                Text("原图已标记到回收站：彻底删除后净省 \(size(net))")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Text("这批压缩没变小（\(size(-net))），别急着删原图")
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
