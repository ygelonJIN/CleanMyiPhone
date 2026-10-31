import Foundation

// MARK: - 媒体类型标签

enum MediaKind: String, Hashable {
    case photo
    case video

    var label: String { self == .photo ? "照片" : "视频" }
    var symbol: String { self == .photo ? "photo" : "video" }
}

struct MediaTag: OptionSet, Hashable {
    let rawValue: Int

    static let screenshot = MediaTag(rawValue: 1 << 0)
    static let panorama   = MediaTag(rawValue: 1 << 1)
    static let portrait   = MediaTag(rawValue: 1 << 2)
    static let selfie     = MediaTag(rawValue: 1 << 3)
    static let live       = MediaTag(rawValue: 1 << 4)
    static let slomo      = MediaTag(rawValue: 1 << 5)
    static let timelapse  = MediaTag(rawValue: 1 << 6)
    static let burst      = MediaTag(rawValue: 1 << 7)
    static let favorite   = MediaTag(rawValue: 1 << 8)
    static let hidden     = MediaTag(rawValue: 1 << 9)

    static let ordered: [MediaTag] = [
        .favorite, .hidden, .live, .burst, .portrait, .selfie,
        .screenshot, .panorama, .slomo, .timelapse
    ]

    var label: String {
        switch self {
        case .screenshot: return "截图"
        case .panorama:   return "全景"
        case .portrait:   return "人像"
        case .selfie:     return "自拍"
        case .live:       return "实况"
        case .slomo:      return "慢动作"
        case .timelapse:  return "延时"
        case .burst:      return "连拍"
        case .favorite:   return "收藏"
        case .hidden:     return "已隐藏"
        default:          return "其他"
        }
    }
}

// MARK: - 资产

struct Asset: Identifiable, Hashable {
    let id: String
    let fileName: String
    let folder: String
    let byteSize: Int64
    let createdAt: Date
    let kind: MediaKind
    let tags: MediaTag
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: Double

    /// 本机没有原图（iCloud「优化 iPhone 储存空间」或仅存在于云端）
    var isCloudOnly: Bool { byteSize == 0 }

    var fileExtension: String { (fileName as NSString).pathExtension.uppercased() }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    var dateText: String {
        createdAt.formatted(.dateTime.year().month().day().hour().minute())
    }

    var durationText: String? {
        guard kind == .video, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var resolutionText: String {
        pixelWidth > 0 && pixelHeight > 0 ? "\(pixelWidth) × \(pixelHeight)" : "—"
    }
}

// MARK: - 排序

enum SortKey: String, CaseIterable, Identifiable {
    case date, size, name

    var id: String { rawValue }
    var label: String {
        switch self {
        case .date: return "时间"
        case .size: return "大小"
        case .name: return "文件名"
        }
    }
}

enum ViewMode: String, CaseIterable, Identifiable {
    // 只有两档有用：网格、列表。统计视图已搬到概览页的饼图矩阵。
    case grid, list

    var id: String { rawValue }
    var label: String {
        switch self {
        case .grid: return "缩略图"
        case .list: return "列表"
        }
    }
    var symbol: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

// MARK: - 设备快照

struct DeviceSnapshot: Identifiable, Hashable {
    let id: String
    let name: String
    let model: String
    let isReady: Bool

    static let fixture = DeviceSnapshot(id: "fixture", name: "iPhone（模拟）", model: "iPhone 15 Pro", isReady: true)
}
