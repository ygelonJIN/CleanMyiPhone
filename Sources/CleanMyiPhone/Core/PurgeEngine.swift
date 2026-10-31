import Foundation

struct DeleteOutcome {
    var succeeded: [Asset.ID] = []
    var failed: [(id: Asset.ID, message: String)] = []

    var succeededBytes: Int64 = 0

    var summary: String {
        if failed.isEmpty {
            return "已从设备删除 \(succeeded.count) 项"
        }
        return "成功 \(succeeded.count) 项，失败 \(failed.count) 项"
    }
}

enum PurgeError: LocalizedError {
    case deviceUnavailable
    case unsupported

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable: return "设备未连接"
        case .unsupported: return "当前数据源不支持删除"
        }
    }
}

/// 真删引擎：把回收站里的标记变成设备侧删除。
@MainActor
final class PurgeEngine {

    private let trash: TrashStore
    private let source: () -> any DeviceSource

    init(trash: TrashStore, source: @escaping () -> any DeviceSource) {
        self.trash = trash
        self.source = source
    }

    /// 分批删除，逐条记录结果。成功的从回收站移除。
    func purge(_ entries: [TrashStore.Entry]) async -> DeleteOutcome {
        var outcome = DeleteOutcome()
        guard !entries.isEmpty else { return outcome }

        let sizeByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.byteSize) })
        let batchSize = 100

        var index = 0
        while index < entries.count {
            let batch = Array(entries[index..<min(index + batchSize, entries.count)])
            index += batch.count

            let result = await source().delete(ids: batch.map(\.id))
            outcome.succeeded.append(contentsOf: result.succeeded)
            outcome.failed.append(contentsOf: result.failed)
            outcome.succeededBytes += result.succeeded.reduce(Int64(0)) { $0 + (sizeByID[$1] ?? 0) }
        }

        trash.remove(ids: outcome.succeeded)
        return outcome
    }
}
