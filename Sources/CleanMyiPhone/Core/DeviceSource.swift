import AppKit
import Foundation

/// 一批删除的结论。
///
/// 三样东西缺一不可（2026-11 用户报「删一半成功一半失败，不知道原因」之后定的）：
/// - `succeeded`：这批里设备回执删掉的
/// - `failed`：**逐条**原因，不再是「整批一句话」
/// - `timedOut`：设备压根没回执。这种情况调用方必须**停下后面的批次**，
///   因为通道已经不可信，继续发只会一路超时（还会让界面永远转圈）
struct DeleteBatchResult {
    var succeeded: [Asset.ID] = []
    var failed: [(id: Asset.ID, message: String)] = []
    var timedOut = false
}

/// 数据来源抽象：真机走 PTP，开发时走 Fixture。
protocol DeviceSource: AnyObject {
    var displayName: String { get }
    var supportsDeletion: Bool { get }

    /// 开始/重复一次枚举，返回全量资产。
    func load() async throws -> [Asset]

    /// 按需取缩略图（设备端生成，不下载原图）。
    func thumbnail(for asset: Asset, maxPixel: Int) async -> NSImage?

    /// 从设备删除，逐条返回结果（由 PurgeEngine 调用）。
    func delete(ids: [Asset.ID]) async -> DeleteBatchResult
}
