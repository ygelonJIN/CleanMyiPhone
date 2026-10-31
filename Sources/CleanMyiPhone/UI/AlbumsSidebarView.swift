import SwiftUI

/// 照片的资料库筛选。侧栏、工具栏筛选菜单都从这里生成，顺序按 Apple 照片的习惯。
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, photos, videos, favorites, screenshots, hidden, trashed

    var id: String { rawValue }

    static var displayOrder: [LibraryFilter] {
        [.all, .photos, .videos, .favorites, .screenshots, .hidden, .trashed]
    }

    var title: String {
        switch self {
        case .all: return "全部照片"
        case .photos: return "照片"
        case .videos: return "视频"
        case .favorites: return "收藏"
        case .hidden: return "已隐藏"
        case .trashed: return "最近删除"
        case .screenshots: return "截图"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "photo.on.rectangle.angled"
        case .photos: return "photo"
        case .videos: return "video"
        case .favorites: return "heart"
        case .hidden: return "eye.slash"
        case .trashed: return "trash"
        case .screenshots: return "camera.viewfinder"
        }
    }
}
