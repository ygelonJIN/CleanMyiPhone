import SwiftUI

/// 照片的资料库筛选。侧栏、工具栏筛选菜单都从这里生成，顺序按 Apple 照片的习惯。
///
/// 说明：**相簿不在这里**。相簿自己是一页（侧栏第二行「相簿」→ 相簿墙），
/// 因为「相簿」是容器范围、「照片/视频」是媒体类型，两者是两个维度，不能并列成 tab。
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, camera, photos, videos, favorites, screenshots, live, raw, hidden, trashed

    var id: String { rawValue }

    /// 侧栏顺序：全部照片 →（相簿，单独一行）→ 相机 → 照片 → 视频 → 收藏 → 截图 → 实况 → RAW → 已隐藏 → 最近删除
    static var displayOrder: [LibraryFilter] {
        [.all, .camera, .photos, .videos, .favorites, .screenshots, .live, .raw, .hidden, .trashed]
    }

    var title: String {
        switch self {
        case .all: return "全部照片"
        case .camera: return "相机"
        case .photos: return "照片"
        case .videos: return "视频"
        case .favorites: return "收藏"
        case .screenshots: return "截图"
        case .live: return "实况"
        case .raw: return "RAW"
        case .hidden: return "已隐藏"
        case .trashed: return "最近删除"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "photo.on.rectangle.angled"
        case .camera: return "camera"
        case .photos: return "photo"
        case .videos: return "video"
        case .favorites: return "heart"
        case .screenshots: return "camera.viewfinder"
        case .live: return "livephoto"
        case .raw: return "camera.aperture"
        case .hidden: return "eye.slash"
        case .trashed: return "trash"
        }
    }

    /// 鼠标停上去的说明：把「判据」翻成人话
    var help: String {
        switch self {
        case .all: return "库里的全部资产（不含已隐藏 / 最近删除）"
        case .camera: return "用手机相机拍/录的（不含从微信、抖音等 App 存进来的）"
        case .photos: return "所有照片（含实况、RAW）"
        case .videos: return "所有视频（含慢动作、电影效果）"
        case .favorites: return "在手机上点过心的"
        case .screenshots: return "截屏（按库里的子类型判定）"
        case .live: return "实况照片：带视频分量的那种，点开能播放"
        case .raw: return "相机拍的原始格式（DNG 等）"
        case .hidden: return "在手机上「隐藏」掉的"
        case .trashed: return "手机「最近删除」里的"
        }
    }
}
