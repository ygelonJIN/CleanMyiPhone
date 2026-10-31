import AppKit
import Foundation

/// 数据来源抽象：真机走 PTP，开发时走 Fixture。
protocol DeviceSource: AnyObject {
    var displayName: String { get }
    var supportsDeletion: Bool { get }

    /// 开始/重复一次枚举，返回全量资产。
    func load() async throws -> [Asset]

    /// 按需取缩略图（设备端生成，不下载原图）。
    func thumbnail(for asset: Asset, maxPixel: Int) async -> NSImage?

    /// 从设备删除，逐条返回结果（由 PurgeEngine 调用）。
    func delete(ids: [Asset.ID]) async -> (succeeded: [Asset.ID], failed: [(id: Asset.ID, message: String)])
}
