import Foundation
import Observation

/// 标记式回收站：只存索引，不复制任何文件。
///
/// **只存在内存里**（2026-11 定的）：退出 App 名单就没了。
/// 以前落盘成 `trash.json`，等于在电脑上永久留一份
/// 「我删过哪些照片、什么时候拍的、多大」的名单 —— 和零痕迹直接冲突，
/// 而且四条退出通路一条都不会去删它。现在这个类完全不碰硬盘。
@MainActor
@Observable
final class TrashStore {

    /// 为什么进的回收站。
    /// 2026-11 用户要求：**压缩成功后自动标记的原图**要和「你自己手标的」分开，
    /// 前者在界面上叫「已压缩待删除」，一眼能看出这批是我压完留下的垃圾。
    enum Reason: String, Codable, Hashable {
        case manual
        case compressed

        var label: String {
            switch self {
            case .manual: return "手动标记"
            case .compressed: return "已压缩待删除"
            }
        }
    }

    struct Entry: Codable, Identifiable, Hashable {
        let id: String          // Asset.id
        let fileName: String
        let folder: String
        let byteSize: Int64
        let createdAt: Date
        let kindRaw: String
        let deviceID: String
        let markedAt: Date
        var reason: Reason = .manual

        var isVideo: Bool { kindRaw == "video" }
    }

    private(set) var entries: [Entry] = []

    /// 按 id 查的索引：**网格每一格每帧都在问「这张已标记吗」**，
    /// 别在查询里现拼 `Set(entries.map(\.id))`（5000 格 × 几百条，全在主线程）。
    private var byID: [Asset.ID: Entry] = [:]

    var count: Int { entries.count }
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.byteSize } }
    /// 其中多少项是「压缩成功后自动标进来的」
    var compressedCount: Int { entries.reduce(0) { $0 + ($1.reason == .compressed ? 1 : 0) } }
    var manualCount: Int { entries.count - compressedCount }
    var ids: Set<Asset.ID> { Set(byID.keys) }

    /// 这一项在不在回收站（O(1)）
    func contains(_ id: Asset.ID) -> Bool { byID[id] != nil }

    private func rebuildIndex() {
        byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    init() {}

    // MARK: - 增删

    func add(_ assets: [Asset], deviceID: String, reason: Reason = .manual) {
        let now = Date()
        var map = byID
        for asset in assets {
            map[asset.id] = Entry(
                id: asset.id,
                fileName: asset.fileName,
                folder: asset.folder,
                byteSize: asset.byteSize,
                createdAt: asset.createdAt,
                kindRaw: asset.kind.rawValue,
                deviceID: deviceID,
                markedAt: now,
                // 已经在站里的保留原来的理由：压缩产生的条目再被手标一次，
                // 也不该丢掉「这张是压缩过的」这个事实
                reason: map[asset.id]?.reason ?? reason
            )
        }
        entries = map.values.sorted { $0.markedAt > $1.markedAt }
        rebuildIndex()
    }

    func remove(ids: some Sequence<Asset.ID>) {
        let set = Set(ids)
        entries.removeAll { set.contains($0.id) }
        rebuildIndex()
    }

    func removeAll() {
        entries.removeAll()
        rebuildIndex()
    }
}
