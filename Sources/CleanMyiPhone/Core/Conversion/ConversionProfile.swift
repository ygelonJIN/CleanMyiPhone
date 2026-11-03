import Foundation
import UniformTypeIdentifiers

/// 一次批量转换的参数：按比例缩、输出格式、质量、是否去实况。
struct ConversionProfile: Sendable, Hashable {
    enum Format: String, Sendable, Hashable, CaseIterable, Codable {
        case heic, jpeg, png

        var utType: UTType {
            switch self {
            case .heic: return .heic
            case .jpeg: return .jpeg
            case .png: return .png
            }
        }

        var fileExtension: String {
            switch self {
            case .heic: return "HEIC"
            case .jpeg: return "JPG"
            case .png: return "PNG"
            }
        }

        var displayName: String {
            switch self {
            case .heic: return "HEIC"
            case .jpeg: return "JPEG"
            case .png: return "PNG"
            }
        }
    }

    /// 线性比例，0.8 / 0.6 / 0.4 这种。按每张图自己的尺寸缩，不按固定长边。
    var ratio: Double = 0.6
    var format: Format = .heic
    var quality: Double = 0.8
    /// 实况照片转成普通静态图（新图不关联 MOV）。
    var stripLive: Bool = true

    var clampedRatio: Double { min(1.0, max(0.05, ratio)) }
    var clampedQuality: Double { min(1.0, max(0.1, quality)) }

    var label: String {
        "\(Int((clampedRatio * 100).rounded()))% · \(format.displayName) · Q\(Int((clampedQuality * 100).rounded()))"
    }

    /// 格子/列表角标上的紧凑写法：`60%·HEIC·Q80`。
    /// 缩略图最小 118pt 宽，带空格的全称塞不下，所以这里用中点连起来。
    /// 用户要在每一格上直接看出「这张会怎么压」，别让人点开压缩站才知道。
    var badgeText: String {
        "\(Int((clampedRatio * 100).rounded()))%·\(format.displayName)·Q\(Int((clampedQuality * 100).rounded()))"
    }

    // MARK: - 体积预估

    /// 预估压缩后的体积。**压缩参数面板和底栏共用这一份**：两处各写一套必然会给出两个数。
    ///
    /// 口径：系数按输出格式挑（JPEG→HEIC 大约省一半，PNG 无损反而涨），
    /// 再乘「比例平方」（线性缩边、面积按平方掉）和质量系数（以 Q0.8 为 1.0）。
    func estimatedBytes(for meta: PhotoLibraryIndex.Meta) -> Int64 {
        estimatedBytes(byteSize: meta.byteSize, typeIdentifier: meta.typeIdentifier)
    }

    /// 同上一份系数，但**基准体积由调用方给**：底栏的「现在」用的是资源合计
    /// （`resourceBytes`，含编辑版与实况视频分量），估算也必须拿同一个数当基准，
    /// 否则前后两栏不是同一个口径，省出来的数字会虚高。
    func estimatedBytes(byteSize: Int64, typeIdentifier: String) -> Int64 {
        Int64(Double(byteSize) * clampedRatio * clampedRatio * formatFactor(typeIdentifier) * qualityFactor)
    }

    /// 拿不到库信息（对不上 `meta`）时的下限估算：只按比例平方缩，**不猜格式收益**。
    /// 宁可估高：底栏要给的是「大概能省多少」，报得太乐观会让人以为白压了。
    func estimatedBytes(forUnresolved byteSize: Int64) -> Int64 {
        Int64(Double(byteSize) * clampedRatio * clampedRatio)
    }

    private func formatFactor(_ typeIdentifier: String) -> Double {
        let lower = typeIdentifier.lowercased()
        switch format {
        case .heic:
            if lower.contains("png") { return 0.12 }
            if lower.contains("raw") { return 0.10 }
            if lower.contains("heic") || lower.contains("heif") { return 0.60 }
            return 0.50
        case .jpeg:
            if lower.contains("raw") { return 0.35 }
            if lower.contains("heic") || lower.contains("heif") { return 1.10 }
            return 1.00
        case .png:
            return 1.60
        }
    }

    private var qualityFactor: Double {
        format == .png ? 1.0 : max(0.35, min(1.5, clampedQuality / 0.8))
    }
}

/// 从相册库里挑出来的一条待转换资产。
struct ConversionItem: Sendable {
    let pk: Int
    let uuid: String
    let directory: String
    let fileName: String
    let uti: String
    let width: Int
    let height: Int
    let subtype: Int
    let playbackStyle: Int
    let isScreenshot: Bool
    let isLive: Bool
    let isVideo: Bool
    let favorite: Bool
    let byteSize: Int64

    var isRAW: Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return uti.contains("raw-image")
            || ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "srw", "pef", "3fr"].contains(ext)
    }
}

extension ConversionItem {
    /// 从相册索引里的一条资产造出转换任务。
    init(meta: PhotoLibraryIndex.Meta) {
        self.pk = meta.pk
        self.uuid = meta.uuid
        self.directory = meta.directory
        self.fileName = meta.fileName
        self.uti = meta.typeIdentifier
        self.width = meta.width
        self.height = meta.height
        self.subtype = meta.subtype
        self.playbackStyle = meta.playbackStyle
        self.isScreenshot = meta.isScreenshot || meta.subtype == 10
        self.isLive = meta.isLive
        self.isVideo = meta.isVideo
        self.favorite = meta.isFavorite
        self.byteSize = meta.byteSize
    }
}

/// UI 用的压缩信息：原图和副本配对后，算出比例、格式、体积变化。
struct CompressionDisplay: Sendable {
    enum Role: Sendable, Equatable { case original, copy }

    let role: Role
    let originalSize: Int64
    let newSize: Int64
    let ratio: Double
    let fromFormat: String
    let toFormat: String
    let removedLive: Bool
    let quality: Int?

    init(role: Role, original: PhotoLibraryIndex.Meta, copy: PhotoLibraryIndex.Meta) {
        self.role = role
        self.originalSize = original.byteSize
        self.newSize = copy.byteSize
        let originalEdge = max(original.width, original.height)
        let copyEdge = max(copy.width, copy.height)
        self.ratio = originalEdge > 0 ? Double(copyEdge) / Double(originalEdge) : 1
        self.fromFormat = Self.formatName(uti: original.typeIdentifier, fileName: original.fileName)
        self.toFormat = Self.formatName(uti: copy.typeIdentifier, fileName: copy.fileName)
        self.removedLive = original.isLive && !copy.isLive
        self.quality = Self.quality(from: copy.importedBy)
    }

    private static func quality(from importedBy: String) -> Int? {
        guard let part = importedBy.split(separator: ".").last(where: { $0.hasPrefix("q") }) else {
            return nil
        }
        return Int(part.dropFirst())
    }

    private static func formatName(uti: String, fileName: String) -> String {
        let lower = uti.lowercased()
        if lower.contains("heic") || lower.contains("heif") { return "HEIC" }
        if lower.contains("jpeg") { return "JPEG" }
        if lower.contains("png") { return "PNG" }
        if lower.contains("raw") { return "RAW" }
        return (fileName as NSString).pathExtension.uppercased()
    }

    var percentText: String { "\(Int((ratio * 100).rounded()))%" }

    var sizeText: String {
        "\(ByteCountFormatter.string(fromByteCount: originalSize, countStyle: .file)) → "
            + ByteCountFormatter.string(fromByteCount: newSize, countStyle: .file)
    }

    var newSizeText: String {
        ByteCountFormatter.string(fromByteCount: newSize, countStyle: .file)
    }

    /// 副本右下角的短标签：`60% · HEIC → JPEG`，不再重复“压缩”两个字。
    var copyBadge: String {
        var parts = [percentText]
        if let formatText { parts.append(formatText) }
        return parts.joined(separator: " · ")
    }

    var formatText: String? {
        fromFormat == toFormat ? nil : "\(fromFormat) → \(toFormat)"
    }

    var shortLabel: String {
        if ratio < 0.99 { return "压缩 \(percentText)" }
        if let formatText { return formatText }
        if removedLive { return "去实况" }
        return "压缩版"
    }

    /// 副本第一行：`PNG→JPEG · 80%`
    var formatPercentLabel: String {
        var parts: [String] = []
        if let formatText { parts.append(formatText) }
        parts.append(percentText)
        return parts.joined(separator: " · ")
    }

    /// 副本第二行：`去实况 · 质量60% · 313 KB`
    var qualitySizeLabel: String {
        var parts: [String] = []
        if removedLive { parts.append("去实况") }
        if let quality { parts.append("质量\(quality)%") }
        parts.append(newSizeText)
        return parts.joined(separator: " · ")
    }

    /// 列表里的一行：`PNG→JPEG · 80% · 质量60% · 313 KB`
    var detailLabel: String {
        [formatPercentLabel, qualitySizeLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var label: String {
        var parts: [String] = []
        if ratio < 0.99 { parts.append("压缩 \(percentText)") }
        if let formatText { parts.append(formatText) }
        if removedLive { parts.append("去实况") }
        if let quality { parts.append("Q\(quality)") }
        parts.append(sizeText)
        return parts.joined(separator: " · ")
    }
}

/// 一个已经写完文件的转换结果，等着进数据库。
struct ConversionRecord: Sendable {
    let originalPK: Int
    let originalFileName: String
    let originalUUID: String
    /// 原图体积。结果卡的「省了多少」只认它 —— 转换结束后选中被清掉了，
    /// 再回去从列表里捞原图大小会捞到 0，于是把「省了 2 MB」显示成「体积增加 332 KB」。
    let originalSize: Int64
    var newPK: Int
    let newUUID: String
    let directory: String
    let newFileName: String
    let newUTI: String
    let newWidth: Int
    let newHeight: Int
    let newSize: Int64
    let quality: Int
    let isScreenshot: Bool
    let favorite: Bool
}

enum ConversionDBError: LocalizedError {
    case cannotPrepare(String)
    case sqlFailed(String)
    case integrityFailed

    var errorDescription: String? {
        switch self {
        case .cannotPrepare(let detail): return "准备转换库失败：\(detail)"
        case .sqlFailed(let sql): return "改库失败：\(sql.prefix(120))"
        case .integrityFailed: return "改完的库完整性检查没过"
        }
    }
}
