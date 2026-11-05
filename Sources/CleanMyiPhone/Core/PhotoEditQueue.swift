import Foundation
import Observation

/// 修改站：收藏 / 移动相簿 / 新建相簿的**暂存区**。
///
/// 为什么必须攒着一起写（2026-11 真机验证过三件事都通，代价也量到了）：
/// 改手机的 `Photos.sqlite` 只能**整份覆盖**（下 297 MB + 上 297 MB + 重启相册服务），
/// 一批大约 40–60 秒。所以和回收站、压缩站一样：点按钮只记意图，到站里点「写回手机」才动设备。
///
/// 合并规矩（同一张反复点，只留最终状态）：
/// - 收藏点两次 = 回到原样，条目自动消失；
/// - 移动点两次 = 保留「最早从哪来 → 最后到哪去」，如果两头是同一本，条目消失；
/// - 新建相簿同名只建一本；撤掉新建相簿时，引用它的移动条目一起撤。
@MainActor
@Observable
final class PhotoEditQueue {

    /// 相簿引用：已存在的用真实 PK；同一批里新建的是负的临时 ID（写库时才换成真 PK）。
    struct AlbumRef: Hashable, Identifiable {
        let id: Int
        let title: String
        var isNew: Bool { id < 0 }
    }

    struct Entry: Identifiable, Hashable {
        var asset: Asset
        /// nil = 这张不改收藏；true / false = 改成这个值
        var favorite: Bool?
        /// 这张在库里的原始收藏状态（用来判断「点回来就该消失」）
        var originalFavorite: Bool
        /// 从哪本相簿移出（nil = 只加入，不移动）
        var moveFrom: Int?
        /// 移到哪本相簿（nil 且 moveFrom 非 nil = 只从相簿里移出）
        var moveTo: AlbumRef?
        var markedAt: Date

        var id: Asset.ID { asset.id }
        var hasChange: Bool { favorite != nil || moveFrom != nil || moveTo != nil }
    }

    private(set) var entries: [Entry] = []
    /// 这一批里要新建的相簿（按创建顺序）
    private(set) var newAlbums: [AlbumRef] = []

    /// 按 id 查的索引：网格每一格每帧都在问「这张有暂存改动吗」，
    /// 一律走这张表，别在 body 里 `first(where:)`（同 `PhotoLibraryIndex` 那条性能红线）。
    private var byID: [Asset.ID: Entry] = [:]

    private var nextTempID = -1

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    var albumCount: Int { newAlbums.count }
    /// 只建一本空相簿也算「有活要干」
    var hasWork: Bool { !entries.isEmpty || !newAlbums.isEmpty }
    /// 侧栏那颗数字：改动条数 + 待建相簿数
    var badgeCount: Int { entries.count + newAlbums.count }
    var ids: Set<Asset.ID> { Set(byID.keys) }

    init() {}

    // MARK: - 查询（O(1)）

    func contains(_ id: Asset.ID) -> Bool { byID[id] != nil }
    func entry(for id: Asset.ID) -> Entry? { byID[id] }

    /// 这张暂存成的收藏状态（没改返回 nil）
    func favorite(for id: Asset.ID) -> Bool? { byID[id]?.favorite }

    /// 这张要移到哪本相簿（没移动返回 nil）
    func moveTarget(for id: Asset.ID) -> AlbumRef? { byID[id]?.moveTo }

    /// 这张有「移入 / 移出相簿」的暂存吗（两个方向都算）
    func hasMove(_ id: Asset.ID) -> Bool {
        guard let entry = byID[id] else { return false }
        return entry.moveFrom != nil || entry.moveTo != nil
    }

    /// 这张要从哪本相簿移出
    func moveSource(for id: Asset.ID) -> Int? { byID[id]?.moveFrom }

    // MARK: - 暂存

    /// 收藏 / 取消收藏。`original` 是库里当前的状态（调用方从 `meta` 取）。
    /// 再点一次就回到原样（条目消失）。
    func toggleFavorite(_ asset: Asset, original: Bool) {
        var entry = byID[asset.id] ?? Entry(asset: asset, favorite: nil,
                                            originalFavorite: original,
                                            moveFrom: nil, moveTo: nil, markedAt: Date())
        let current = entry.favorite ?? original
        let next = !current
        entry.favorite = (next == entry.originalFavorite) ? nil : next
        entry.markedAt = Date()
        store(entry)
    }

    /// 把一批照片移到相簿（`to`），`from` 是「从哪本移出」：
    /// - 在某个相簿里操作 → 传当前相簿 ID（移动）
    /// - 在「全部照片」里操作 → 传 nil（只加入，不从任何相簿拿掉）
    /// - `to == nil` 且 `from != nil` → 只从相簿里移出
    func move(_ assets: [Asset], from: Int?, to: AlbumRef?) {
        for asset in assets {
            var entry = byID[asset.id] ?? Entry(asset: asset, favorite: nil,
                                                originalFavorite: false,
                                                moveFrom: nil, moveTo: nil, markedAt: Date())
            // 最早的来源才算来源：A→B 再 B→C，最终是 A→C
            if entry.moveFrom == nil { entry.moveFrom = from }
            entry.moveTo = to
            // 两头同一本 = 没动
            if let target = entry.moveTo, let from = entry.moveFrom, target.id == from {
                entry.moveFrom = nil
                entry.moveTo = nil
            }
            entry.markedAt = Date()
            store(entry)
        }
    }

    /// 撤掉这些项的「移动相簿」暂存（收藏改动保留；两者都空了条目就消失）。
    /// 2026-11 用户定的新交互：点已暂存移动的格子 = 选中，然后在底栏点「取消移入」走这里。
    func clearMoves(_ ids: some Sequence<Asset.ID>) {
        for id in ids {
            guard var entry = byID[id] else { continue }
            entry.moveFrom = nil
            entry.moveTo = nil
            entry.markedAt = Date()
            store(entry)
        }
    }

    /// 新建一本相簿，返回可以立刻用于移动的引用（负的临时 ID）。
    func createAlbum(title: String) -> AlbumRef {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = newAlbums.first(where: { $0.title == clean }) { return existing }
        let ref = AlbumRef(id: nextTempID, title: clean)
        nextTempID -= 1
        newAlbums.append(ref)
        return ref
    }

    /// 撤掉一本还没写回的新相簿：引用它的移动条目一起撤（不然写库时会找不到目标）。
    func removeNewAlbum(_ ref: AlbumRef) {
        // 引用它的条目：把「目标」清掉；如果它同时是「来源」，也清掉。
        for var entry in entries where entry.moveTo?.id == ref.id || entry.moveFrom == ref.id {
            if entry.moveTo?.id == ref.id { entry.moveTo = nil }
            if entry.moveFrom == ref.id { entry.moveFrom = nil }
            store(entry)
        }
        newAlbums.removeAll { $0.id == ref.id }
    }

    /// 把一批资产从站里撤掉（写回成功后清场、或删除时联动）
    func remove(_ ids: some Sequence<Asset.ID>) {
        let set = Set(ids)
        entries.removeAll { set.contains($0.id) }
        rebuildIndex()
    }

    func remove(_ id: Asset.ID) { remove([id]) }

    func clear() {
        entries.removeAll()
        newAlbums.removeAll()
        rebuildIndex()
    }

    /// 把这一批转成改库操作。`pk` 负责把 Asset 映射回相册库的 Z_PK。
    func operations(pk: (Asset) -> Int?) -> [PhotosDBEdit.Op] {
        var ops: [PhotosDBEdit.Op] = []
        for album in newAlbums {
            ops.append(.createAlbum(tempID: album.id, title: album.title))
        }
        for entry in entries {
            guard let assetPK = pk(entry.asset) else { continue }
            if let favorite = entry.favorite {
                ops.append(.favorite(pk: assetPK, value: favorite))
            }
            if let from = entry.moveFrom {
                ops.append(.membership(assetPK: assetPK, album: .existing(from), present: false))
            }
            if let to = entry.moveTo {
                if to.isNew {
                    ops.append(.membership(assetPK: assetPK, album: .created(to.id), present: true))
                } else {
                    ops.append(.membership(assetPK: assetPK, album: .existing(to.id), present: true))
                }
            }
        }
        return ops
    }

    /// 写回成功后：把「新建相簿」的临时 ID 换成真 PK，供内存索引补账用。
    func resolveCreatedAlbums(_ mapping: [Int: Int]) -> [AlbumRef] {
        var resolved: [AlbumRef] = []
        for album in newAlbums {
            guard let real = mapping[album.id] else { continue }
            resolved.append(AlbumRef(id: real, title: album.title))
        }
        return resolved
    }

    // MARK: - 内部

    private func store(_ entry: Entry) {
        if !entry.hasChange {
            entries.removeAll { $0.id == entry.id }
            byID[entry.id] = nil
            return
        }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        byID[entry.id] = entry
    }

    private func rebuildIndex() {
        byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }
}
