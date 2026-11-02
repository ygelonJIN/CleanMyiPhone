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

    var count: Int { entries.count }
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.asset.byteSize } }
    var ids: Set<Asset.ID> { Set(entries.map(\.id)) }
    var isEmpty: Bool { entries.isEmpty }

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
        var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for asset in assets {
            byID[asset.id] = Entry(asset: asset, profile: profile, markedAt: now)
        }
        entries = byID.values.sorted { $0.markedAt > $1.markedAt }
    }

    func remove(ids: some Sequence<Asset.ID>) {
        let set = Set(ids)
        entries.removeAll { set.contains($0.id) }
    }

    func removeAll() {
        entries.removeAll()
    }
}
