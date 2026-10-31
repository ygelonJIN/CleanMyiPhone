import SwiftUI

enum Theme {
    static let photo = Color(red: 0.32, green: 0.58, blue: 0.99)
    static let video = Color(red: 0.62, green: 0.44, blue: 0.95)
    static let screenshot = Color(red: 0.20, green: 0.72, blue: 0.78)
    static let live = Color(red: 0.96, green: 0.72, blue: 0.24)
    /// 系统与应用（iOS 本体 + 系统数据）—— 一个实色，别再拿 0.55 透明灰凑数
    static let system = Color(red: 0.56, green: 0.60, blue: 0.66)
    /// 应用（App 本体 + 文稿 + 缓存）
    static let app = Color(red: 0.35, green: 0.66, blue: 0.52)
    /// 相簿排行的条形色
    static let album = Color(red: 0.40, green: 0.52, blue: 0.78)
    static let other = Color.secondary.opacity(0.26)

    static func tint(for kind: MediaKind) -> Color {
        kind == .video ? video : photo
    }
}
