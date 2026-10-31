import AppKit
import Foundation
import ImageIO

/// 通过 AFC 读设备上的文件。
///
/// **不在主线程跑**：AFC 的每次读都是同步阻塞的，放在 MainActor 上会把界面卡住
/// （滚动网格、切预览都会顿）。这里所有工作都串行排在一个 utility 队列上，
/// 调用方用 `await` 等结果，主线程只负责画。
final class DeviceFiles: @unchecked Sendable {

    static let shared = DeviceFiles()

    private let queue = DispatchQueue(label: "cmi.devicefiles", qos: .utility)
    private var api: MobileDeviceAPI?
    private var device: UnsafeMutableRawPointer?
    private var afc: UnsafeMutableRawPointer?
    private var pathIndex: [String: String] = [:]

    private(set) var lastError: String?

    // MARK: - 会话

    private func prepareLocked() throws {
        if afc != nil { return }
        let api = try MobileDeviceAPI.shared()
        self.api = api
        let device = try api.firstDevice(timeout: 10)
        self.device = device
        try api.openSession(device)
        self.afc = try api.openAFC(device)
    }

    private func buildIndexLocked() {
        guard pathIndex.isEmpty, let api, let afc else { return }
        guard let folders = try? api.listDirectory(afc, path: "/DCIM") else { return }
        for folder in folders where folder.first?.isNumber == true {
            let path = "/DCIM/\(folder)"
            for name in (try? api.listDirectory(afc, path: path)) ?? [] {
                pathIndex[name] = "\(path)/\(name)"
            }
        }
    }

    /// 清缓存 / 出错后重置会话：下次调用会重新建 AFC 连接、重建 DCIM 索引
    func reset() {
        queue.sync {
            pathIndex.removeAll()
            afc = nil
            api = nil
            device = nil
        }
    }

    // MARK: - 单个文件下载

    func download(fileName: String,
                  libraryName: String? = nil,
                  to directory: URL,
                  progress: ((Int64) -> Void)? = nil) async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                continuation.resume(returning: self.downloadLocked(fileName: fileName,
                                                                  libraryName: libraryName,
                                                                  to: directory,
                                                                  progress: progress))
            }
        }
    }

    private func downloadLocked(fileName: String,
                                libraryName: String?,
                                to directory: URL,
                                progress: ((Int64) -> Void)?) -> URL? {
        do {
            try prepareLocked()
            buildIndexLocked()
        } catch {
            lastError = "准备失败：\(error.localizedDescription)"
            return nil
        }
        guard let api, let afc else {
            lastError = "AFC 未就绪"
            return nil
        }

        var candidates: [String] = [fileName]
        if let libraryName { candidates.insert(libraryName, at: 0) }

        var remote: String?
        for candidate in candidates {
            if let hit = pathIndex[candidate] { remote = hit; break }
            let upper = candidate.uppercased()
            if let hit = pathIndex.first(where: { $0.key.uppercased() == upper })?.value {
                remote = hit; break
            }
        }

        if remote == nil {
            let digits = fileName.filter(\.isNumber)
            let ext = (fileName as NSString).pathExtension.lowercased()
            if digits.count >= 3 {
                let matches = pathIndex.filter {
                    $0.key.filter(\.isNumber).hasSuffix(digits)
                        && ($0.key as NSString).pathExtension.lowercased() == ext
                }
                if matches.count == 1 { remote = matches.first?.value }
            }
        }

        guard let remote else {
            lastError = "DCIM 里找不到 \(fileName)"
            return nil
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let local = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: local.path) { return local }

        guard let ref = try? api.openFile(afc, path: remote) else {
            lastError = "打不开 \(remote)"
            return nil
        }
        defer { api.closeFile(afc, ref) }

        try? FileManager.default.removeItem(at: local)
        FileManager.default.createFile(atPath: local.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: local) else { return nil }
        defer { try? handle.close() }

        var slice = 0
        var received: Int64 = 0
        var zeroReads = 0
        while true {
            if let chunk = api.readChunk(afc, ref) {
                handle.write(chunk)
                received += Int64(chunk.count)
                zeroReads = 0
                slice += 1
                if slice % 16 == 0 { progress?(received) }
                continue
            }
            // USB 通道会瞬时没数据，0 字节不等于读完；不重试就会拿到半张图 → 花屏
            zeroReads += 1
            if zeroReads > 400 { break }
            usleep(30_000)
        }
        return local
    }

    // MARK: - 网格缩略图（AFC 读原图 → ImageIO 降采样）

    static var thumbDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cleanmyiphone", isDirectory: true)
            .appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var rawCacheDirectory: URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanmyiphone-raw", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 返回 **JPEG 数据**而不是 NSImage。
    /// NSImage 在后台队列创建、拿到主线程渲染会变成黑图（预览"闪一下就黑"就是它）。
    func thumbnailData(for asset: Asset, libraryName: String?, maxPixel: Int) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                continuation.resume(returning: self.thumbnailDataLocked(asset: asset,
                                                                       libraryName: libraryName,
                                                                       maxPixel: maxPixel))
            }
        }
    }

    private func thumbnailDataLocked(asset: Asset, libraryName: String?, maxPixel: Int) -> Data? {
        let key = "thumb-\(Self.safeName(asset.fileName))-\(maxPixel).jpg"
        let cached = Self.thumbDirectory.appendingPathComponent(key)
        if let data = try? Data(contentsOf: cached), !data.isEmpty { return data }

        // 视频不在网格里拉原文件，太贵
        guard asset.kind == .photo else { return nil }

        guard let url = downloadLocked(fileName: asset.fileName,
                                       libraryName: libraryName,
                                       to: Self.rawCacheDirectory,
                                       progress: nil) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }

        guard let data = Self.downsampleJPEG(url, maxPixel: maxPixel) else {
            // 解不出来（半截图）就把缓存清掉，避免一直花屏
            try? FileManager.default.removeItem(at: cached)
            return nil
        }
        try? data.write(to: cached)
        return data
    }

    static func safeName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_")
    }

    /// ImageIO 降采样并编码成 JPEG（只返回字节，不碰 NSImage）
    static func downsampleJPEG(_ url: URL, maxPixel: Int, quality: Double = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
