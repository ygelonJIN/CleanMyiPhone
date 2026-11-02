import Foundation

/// 一条没删掉的原因。带文件名是为了让界面能直接说「IMG_1234.HEIC：设备只读」，
/// 而不是「失败 3 项」这种没法处理的汇总。
struct PurgeFailure: Identifiable, Hashable {
    let id: Asset.ID
    let name: String
    let bytes: Int64
    let reason: String
}

/// 删完之后给用户看的那张单子。
struct PurgeReport: Identifiable {
    let id = UUID()
    var total = 0
    var succeededIDs: [Asset.ID] = []
    var succeededBytes: Int64 = 0
    /// 失败项**仍然在回收站里**，可以直接重试
    var failures: [PurgeFailure] = []
    /// 设备中途失去回执，后面几批根本没发出去
    var aborted = false
    var skipped = 0

    var succeededCount: Int { succeededIDs.count }
    var hasFailures: Bool { !failures.isEmpty }

    var title: String {
        if failures.isEmpty { return "已彻底删除 \(succeededCount) 项" }
        if succeededCount == 0 { return "\(failures.count) 项都没删掉" }
        return "已删除 \(succeededCount) 项，\(failures.count) 项没删掉"
    }
}

/// 删除过程中的进度快照。「正在删除」那张弹窗只读这个值。
struct PurgeProgress: Equatable {
    var total = 0
    var processed = 0
    var succeeded = 0
    var failed = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    /// 正在处理的那一批里的第一个文件名，给弹窗一行「正在删 xxx」
    var currentName = ""
    /// 这一批是大致哪几项（1 基），弹窗写「第 201–300 项 / 共 412 项」
    var batchFrom = 0
    var batchTo = 0

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(processed) / Double(total))
    }

    var rangeText: String {
        guard total > 0 else { return "" }
        if batchTo <= batchFrom { return "共 \(total) 项" }
        return "第 \(batchFrom)–\(batchTo) 项 · 共 \(total) 项"
    }
}

struct DeleteOutcome {
    var total = 0
    var succeeded: [Asset.ID] = []
    var succeededBytes: Int64 = 0
    var failures: [PurgeFailure] = []
    var aborted = false
    var skipped = 0

    var summary: String {
        if failures.isEmpty {
            return "已从设备删除 \(succeeded.count) 项"
        }
        return "成功 \(succeeded.count) 项，失败 \(failures.count) 项"
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
///
/// 两条不变量（2026-11 定的）：
/// 1. **每一条都要有结论** —— 成功的进 `succeeded`，失败的带文件名 + 原因进 `failures`。
///    以前只留一句 `summary`，用户看不出是哪几张没删掉、为什么。
/// 2. **设备失联就停** —— 一批超时（`DeleteBatchResult.timedOut`）之后不再发下一批，
///    剩下的标「没有执行」。通道已经不可信，硬发只会一路超时把界面卡住。
@MainActor
final class PurgeEngine {

    /// 一批多少条。PTP 的 `requestDeleteFiles` 一次调用能删一批，
    /// 太小会让「删 500 张」变成 100 次往返，太大则一批久到进度条不动。
    static let batchSize = 100

    private let trash: TrashStore
    private let source: () -> any DeviceSource

    init(trash: TrashStore, source: @escaping () -> any DeviceSource) {
        self.trash = trash
        self.source = source
    }

    /// 分批删除，逐条记录结果。成功的从回收站移除，失败的**原样留着**。
    /// `onProgress` 每批回调两次（开始删之前 / 这批有结论之后），
    /// 界面靠它画那个「删除中」弹窗。
    func purge(_ entries: [TrashStore.Entry],
               onProgress: @escaping (PurgeProgress) -> Void) async -> DeleteOutcome {
        var outcome = DeleteOutcome()
        outcome.total = entries.count
        guard !entries.isEmpty else { return outcome }

        let nameByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.fileName) })
        let sizeByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.byteSize) })
        let bytesTotal = entries.reduce(Int64(0)) { $0 + $1.byteSize }

        var progress = PurgeProgress(total: entries.count, bytesTotal: bytesTotal)
        onProgress(progress)

        var index = 0
        while index < entries.count {
            let batch = Array(entries[index..<min(index + Self.batchSize, entries.count)])
            let from = index + 1
            index += batch.count
            let to = index

            progress.currentName = batch.first?.fileName ?? ""
            progress.batchFrom = from
            progress.batchTo = to
            onProgress(progress)

            let result = await source().delete(ids: batch.map(\.id))

            let okSet = Set(result.succeeded)
            let failedIDs = Set(result.failed.map(\.id))

            for id in result.succeeded {
                outcome.succeeded.append(id)
                outcome.succeededBytes += sizeByID[id] ?? 0
            }
            for (id, message) in result.failed {
                // `id` 为空 = 设备对整个请求报了一句错，没有指名到文件：
                // 把这句话落到这一批里**既没成功、也没有逐条原因**的那些项上
                let targets = id.isEmpty
                    ? batch.map(\.id).filter { !okSet.contains($0) && !failedIDs.contains($0) }
                    : [id]
                for target in targets where !okSet.contains(target) {
                    outcome.failures.append(
                        PurgeFailure(
                            id: target,
                            name: nameByID[target] ?? "未知项",
                            bytes: sizeByID[target] ?? 0,
                            reason: message
                        )
                    )
                }
            }

            progress.processed = index
            progress.succeeded = outcome.succeeded.count
            progress.failed = outcome.failures.count
            progress.bytesDone = outcome.succeededBytes

            if result.timedOut {
                // 设备从这一批起就不回话了：剩下的**不发了**，逐条标「没有执行」
                outcome.aborted = true
                let rest = Array(entries[index...])
                outcome.skipped = rest.count
                for entry in rest {
                    outcome.failures.append(
                        PurgeFailure(
                            id: entry.id,
                            name: entry.fileName,
                            bytes: entry.byteSize,
                            reason: "没有执行：设备在前面那一批就没有回执了（解锁 iPhone、拔插数据线后重试）"
                        )
                    )
                }
                progress.failed = outcome.failures.count
                progress.processed = entries.count
                onProgress(progress)
                break
            }

            onProgress(progress)
        }

        trash.remove(ids: outcome.succeeded)
        return outcome
    }
}
