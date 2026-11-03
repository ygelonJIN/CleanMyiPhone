import Foundation
import Observation

/// 压缩站：**先只记意图**，到站里二次确认才真的压缩。
///
/// 为什么要这一步（2026-11 用户定的）：压缩要改手机的 `Photos.sqlite`，**每批一次
/// 302 MB 双向**（整份下 + 整份上），压一张 1 MB 的图也是这个价。所以第一次点「压缩」
/// 只做标记（选好比例/格式/质量、记下要压哪几张），真正执行放到「压缩站」里，
/// 让用户攒够一批再一次性付那 300 MB。
///
/// 和回收站一样**只存在内存里**：退出 App 名单就没了（零痕迹那条规矩）。
@MainActor
@Observable
final class CompressionQueue {

    struct Entry: Identifiable, Equatable {
        let asset: Asset
        let profile: ConversionProfile
        let markedAt: Date

        var id: Asset.ID { asset.id }
        var isVideo: Bool { asset.kind == .video }

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.asset.id == rhs.asset.id
                && lhs.profile == rhs.profile
                && lhs.markedAt == rhs.markedAt
        }
    }

    private(set) var entries: [Entry] = []

    /// 按 id 查条目：**网格每个格子每帧都在问「这张待压缩吗、参数是什么」**，
    /// 一律走这张预先建好的表。别在查询里 `entries.first(where:)` 或现拼 `Set(map(\.id))`
    /// —— 5000 格 × 几百条，那是几十万次比较，全在主线程（同 `PhotoLibraryIndex` 那条性能红线）。
    private var byID: [Asset.ID: Entry] = [:]

    var count: Int { entries.count }
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.asset.byteSize } }
    var ids: Set<Asset.ID> { Set(byID.keys) }
    var isEmpty: Bool { entries.isEmpty }

    /// 这一项在不在压缩站（O(1)）
    func contains(_ id: Asset.ID) -> Bool { byID[id] != nil }

    /// 这一项的条目（含它标记时的参数）
    func entry(for id: Asset.ID) -> Entry? { byID[id] }

    /// 这一项标记时选的参数（没标记返回 nil）
    func profile(for id: Asset.ID) -> ConversionProfile? { byID[id]?.profile }


    private func rebuildIndex() {
        byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    /// 按参数分组：不同参数必须分别跑一次，**每组都是一次写库**。
    /// 界面（和结果单）要如实说这一点，别让人以为改个比例不花钱。
    var groups: [(profile: ConversionProfile, entries: [Entry])] {
        var order: [ConversionProfile] = []
        var buckets: [ConversionProfile: [Entry]] = [:]
        for entry in entries {
            if buckets[entry.profile] == nil {
                buckets[entry.profile] = []
                order.append(entry.profile)
            }
            buckets[entry.profile]?.append(entry)
        }
        return order.compactMap { profile in
            guard let list = buckets[profile] else { return nil }
            return (profile, list)
        }
    }

    init() {}

    // MARK: - 增删

    /// 标记一批待压缩。**同一张再标记就是改参数**（不会出现两条）。
    func add(_ assets: [Asset], profile: ConversionProfile, deviceID: String) {
        let now = Date()
        var map = byID
        for asset in assets {
            map[asset.id] = Entry(asset: asset, profile: profile, markedAt: now)
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
