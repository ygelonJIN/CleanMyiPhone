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

    /// 一条 AFC 通道 + 它自己的 DCIM 索引。
    /// 照片和视频各用一条：视频要整份下（几十上百 MB），
    /// 挤在同一个串行队列里会把整屏照片缩略图堵死 —— 用户看到的就是「全空」。
    private final class Session {
        var api: MobileDeviceAPI?
        var device: UnsafeMutableRawPointer?
        var afc: UnsafeMutableRawPointer?
        var pathIndex: [String: String] = [:]
        var error: String?

        func prepare() throws {
            if afc != nil { return }
            let api = try MobileDeviceAPI.shared()
            self.api = api
            let device = try api.firstDevice(timeout: 10)
            self.device = device
            try api.openSession(device)
            self.afc = try api.openAFC(device)
        }

        func buildIndex() {
            guard pathIndex.isEmpty, let api, let afc else { return }
            guard let folders = try? api.listDirectory(afc, path: "/DCIM") else { return }
            for folder in folders where folder.first?.isNumber == true {
                let path = "/DCIM/\(folder)"
                for name in (try? api.listDirectory(afc, path: path)) ?? [] {
                    pathIndex[name] = "\(path)/\(name)"
                }
            }
        }

        func reset() {
            pathIndex.removeAll()
            afc = nil
            api = nil
            device = nil
        }
    }

    private let queue = DispatchQueue(label: "cmi.devicefiles", qos: .utility)
    private let photoSession = Session()

    private(set) var lastError: String?

    // 排队作废机制：换排序/换相簿时把还没开始跑的请求一次性丢掉，
    // 免得上一屏的几十个请求继续占着通道。
    private let epochLock = NSLock()
    private var pendingEpoch = 0

    func cancelPending() {
        epochLock.lock()
        pendingEpoch &+= 1
        epochLock.unlock()
    }

    private func currentEpoch() -> Int {
        epochLock.lock()
        defer { epochLock.unlock() }
        return pendingEpoch
    }

    /// 清缓存 / 出错后重置会话：下次调用会重新建 AFC 连接、重建 DCIM 索引
    func reset() {
        queue.sync { photoSession.reset() }
    }

    // MARK: - 单个文件下载

    func download(fileName: String,
                  libraryName: String? = nil,
                  to directory: URL,
                  progress: ((Int64) -> Void)? = nil) async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                let url = self.downloadLocked(session: self.photoSession,
                                              fileName: fileName,
                                              libraryName: libraryName,
                                              to: directory,
                                              progress: progress)
                self.lastError = self.photoSession.error
                continuation.resume(returning: url)
            }
        }
    }

    private func downloadLocked(session: Session,
                                fileName: String,
                                libraryName: String?,
                                to directory: URL,
                                expected: Int64 = 0,
                                progress: ((Int64) -> Void)?) -> URL? {
        do {
            try session.prepare()
            session.buildIndex()
        } catch {
            session.error = "准备失败：\(error.localizedDescription)"
            return nil
        }
        guard let api = session.api, let afc = session.afc else {
            session.error = "AFC 未就绪"
            return nil
        }
        let pathIndex = session.pathIndex

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
                // 先按「数字后缀 + 同扩展名」
                let sameExt = pathIndex.filter {
                    $0.key.filter(\.isNumber).hasSuffix(digits)
                        && ($0.key as NSString).pathExtension.lowercased() == ext
                }
                if sameExt.count == 1 {
                    remote = sameExt.first?.value
                } else {
                    // PTP 报的扩展名不一定和磁盘一致（.JPG / .HEIC），
                    // 数字后缀唯一命中就认它，否则预览会误报「DCIM 里找不到」。
                    let anyExt = pathIndex.filter { $0.key.filter(\.isNumber).hasSuffix(digits) }
                    if anyExt.count == 1 { remote = anyExt.first?.value }
                }
            }
            if remote == nil {
                session.error = "DCIM 里找不到 \(fileName)（索引 \(pathIndex.count) 个文件）"
            }
        }

        guard let remote else {
            session.error = "DCIM 里找不到 \(fileName)"
            return nil
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let local = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: local.path) { return local }

        guard let ref = try? api.openFile(afc, path: remote) else {
            session.error = "打不开 \(remote)"
            return nil
        }
        defer { api.closeFile(afc, ref) }

        try? FileManager.default.removeItem(at: local)
        FileManager.default.createFile(atPath: local.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: local) else { return nil }
        defer { try? handle.close() }

        var slice = 0
        var received: Int64 = 0
        var stalled = 0
        while true {
            if let chunk = api.readChunk(afc, ref) {
                handle.write(chunk)
                received += Int64(chunk.count)
                stalled = 0
                slice += 1
                if slice % 16 == 0 { progress?(received) }
                continue
            }
            // 读到计划字节数才算完。
            // 只看 status == 0 就直接 break 会出大事：USB 通道中途停一拍、status 也是 0，
            // 35 MB 的 DNG 就会被截断，ImageIO 解不出来 → 整批 DNG 全「取不到」。
            let reachedPlan = expected > 0 && received >= expected
            if api.lastReadStatus == 0 && (reachedPlan || expected == 0) {
                stalled += 1
                if stalled > 3 { break }        // 连续 3 拍空读（60 ms）才认尾
                usleep(20_000)
                continue
            }
            stalled += 1
            if stalled > 200 { break }          // 真·读不动了（4 秒）才放弃
            usleep(20_000)
        }
        return local
    }

    /// 按设备的**绝对路径**下载（相册库里就有 `ZDIRECTORY` + `ZFILENAME`）。
    /// 这条路比「名字匹配 DCIM 索引」和「IC 的 PTP 下载」都快：
    /// AFC 实测 36 MB/s，而 IC 的下载是单流小包，几百 MB 的视频会慢到超时。
    /// 预览下载的作废令牌：换目标/关预览时 +1，正在跑的那次会在下一个分块处自我终止
    private var previewEpoch = 0
    private let previewLock = NSLock()

    func cancelPreviewDownload() {
        previewLock.lock(); previewEpoch &+= 1; previewLock.unlock()
    }

    private func currentPreviewEpoch() -> Int {
        previewLock.lock(); defer { previewLock.unlock() }
        return previewEpoch
    }

    func downloadByDevicePath(_ remotePaths: [String],
                              to directory: URL,
                              expected: Int64 = 0,
                              onProgress: ((Int64, Int64) -> Void)? = nil) async -> URL? {
        let epoch = currentPreviewEpoch()
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                let session = self.photoSession
                do { try session.prepare() } catch {
                    session.error = "准备失败：\(error.localizedDescription)"
                    continuation.resume(returning: nil)
                    return
                }
                guard let api = session.api, let afc = session.afc else {
                    session.error = "AFC 未就绪"
                    continuation.resume(returning: nil)
                    return
                }
                for remote in remotePaths {
                    guard let ref = try? api.openFile(afc, path: remote) else { continue }
                    let size = api.fileSize(afc, ref)
                    let name = (remote as NSString).lastPathComponent
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let local = directory.appendingPathComponent(name)
                    try? FileManager.default.removeItem(at: local)
                    FileManager.default.createFile(atPath: local.path, contents: nil)
                    guard let handle = try? FileHandle(forWritingTo: local) else {
                        api.closeFile(afc, ref)
                        continue
                    }
                    // 进度分母优先用**设备报的真实大小**：PTP 的 fileSize 对大视频经常不准，
                    // 拿它当分母就会出现"取到 90/118 MB 就卡住、其实文件已经取完"。
                    let plan = size > 0 ? size : expected
                    var received: Int64 = 0
                    var stalled = 0
                    var aborted = false
                    while true {
                        if self.currentPreviewEpoch() != epoch {
                            aborted = true
                            break
                        }
                        if let chunk = api.readChunk(afc, ref) {
                            handle.write(chunk)
                            received += Int64(chunk.count)
                            stalled = 0
                            onProgress?(received, plan)
                            continue
                        }
                        let reached = plan > 0 && received >= plan
                        if api.lastReadStatus == 0 && (reached || plan == 0) {
                            stalled += 1
                            if stalled > 3 { break }
                            usleep(20_000)
                            continue
                        }
                        stalled += 1
                        if stalled > 200 { break }
                        usleep(20_000)
                    }
                    try? handle.close()
                    api.closeFile(afc, ref)
                    let complete = plan == 0 || received >= plan
                    if aborted || !complete {
                        // 半截文件绝不能留在缓存里冒充完整视频
                        try? FileManager.default.removeItem(at: local)
                        if aborted {
                            continuation.resume(returning: nil)
                            return
                        }
                        continue
                    }
                    if received > 0 {
                        self.lastError = nil
                        continuation.resume(returning: local)
                        return
                    }
                }
                session.error = "按库里的路径打不开 \(remotePaths.first ?? "-")"
                self.lastError = session.error
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - 网格缩略图（AFC 读原图 → ImageIO 降采样）

    /// 缩略图缓存目录。
    /// **权限 0700**：里面是照片的缩小副本，同机其他账户不该能读。
    static var thumbDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cleanmyiphone", isDirectory: true)
            .appendingPathComponent("thumbs", isDirectory: true)
        Self.makePrivateDirectory(base)
        Self.makePrivateDirectory(base.deletingLastPathComponent())
        return base
    }

    /// 临时落盘目录（下原图后立刻删）。权限同样 0700。
    static var rawCacheDirectory: URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanmyiphone-raw", isDirectory: true)
        Self.makePrivateDirectory(url)
        return url
    }

    /// 建目录并强制 0700（默认 0755，同机其他账户能读）
    @discardableResult
    static func makePrivateDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // 已存在的目录不会因为 createDirectory 改权限，显式补一次
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// 缩略图缓存文件名：文件名 + 像素，共享给「视频抽帧」那条路复用
    static func thumbCacheURL(fileName: String, maxPixel: Int) -> URL {
        thumbDirectory.appendingPathComponent("thumb-\(safeName(fileName))-\(maxPixel).jpg")
    }

    /// 把 CGImage 编码成 JPEG 写进缩略图缓存（视频抽帧用）
    static func writeThumbnailCache(_ cg: CGImage, fileName: String, maxPixel: Int, quality: Double = 0.72) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let result = data as Data
        try? result.write(to: thumbCacheURL(fileName: fileName, maxPixel: maxPixel))
        return result
    }

    /// 清掉所有「原图/原视频」级别的一次性落盘。
    /// 缩略图缓存和相册库快照是**故意保留**的（缓存就是它的用途），这里不动。
    static func purgeTransientFiles() {
        emptyDirectory(rawCacheDirectory)
        emptyDirectory(FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanmyiphone-preview", isDirectory: true))
        emptyDirectory(rawCacheDirectory.appendingPathComponent("preview", isDirectory: true))
        // 缓存根目录收紧权限
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cleanmyiphone", isDirectory: true)
        makePrivateDirectory(root)
        makePrivateDirectory(root.appendingPathComponent("thumbs", isDirectory: true))
    }

    /// 清一个目录下的所有文件（不删目录本身）
    static func emptyDirectory(_ url: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: url,
                                                                     includingPropertiesForKeys: nil) else { return }
        for item in items { try? FileManager.default.removeItem(at: item) }
    }

    /// 返回 **JPEG 数据**而不是 NSImage。
    /// NSImage 在后台队列创建、拿到主线程渲染会变成黑图（预览"闪一下就黑"就是它）。
    func thumbnailData(for asset: Asset, libraryName: String?, maxPixel: Int) async -> Data? {
        let epoch = currentEpoch()
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                guard self.currentEpoch() == epoch else {
                    // 排队期间用户换了视图，这一张不必再下
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: self.thumbnailDataLocked(asset: asset,
                                                                       libraryName: libraryName,
                                                                       maxPixel: maxPixel))
            }
        }
    }

    private func thumbnailDataLocked(asset: Asset, libraryName: String?, maxPixel: Int) -> Data? {
        let cached = Self.thumbCacheURL(fileName: asset.fileName, maxPixel: maxPixel)
        if let data = try? Data(contentsOf: cached), !data.isEmpty { return data }

        // 视频不在网格里拉原文件，太贵
        guard asset.kind == .photo else { return nil }

        guard let url = downloadLocked(session: photoSession,
                                       fileName: asset.fileName,
                                       libraryName: libraryName,
                                       to: Self.rawCacheDirectory,
                                       expected: asset.byteSize,
                                       progress: nil) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }

        // 字节数对不上就别浪费解码：先删干净，下次重下
        if asset.byteSize > 0,
           let onDisk = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64,
           onDisk < asset.byteSize {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: cached)
            lastError = "下载不完整 \(onDisk)/\(asset.byteSize)"
            return nil
        }

        guard let data = Self.downsampleJPEG(url, maxPixel: maxPixel) else {
            // 解不出来（半截图）就把缓存清掉，避免一直花屏
            try? FileManager.default.removeItem(at: cached)
            return nil
        }
        try? data.write(to: cached)
        return data
    }

    /// 原图解码：原生尺寸、只做方向校正，不缩放不重编码
    static func decodeOriginal(_ source: CGImageSource, asset: Asset) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(asset.pixelWidth, asset.pixelHeight, 12_000),
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func decodeOriginal(_ url: URL, asset: Asset) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return decodeOriginal(source, asset: asset)
    }

    static func safeName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_")
    }

    // MARK: - 空格预览用的原图（无损）

    static var previewPhotoDirectory: URL {
        let url = rawCacheDirectory.appendingPathComponent("preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 预览取原图：整份下载 → ImageIO **原生尺寸**解码，只做方向校正，不降采样、不重编码。
    /// 返回 CGImage 而不是 NSImage：NSImage 在后台队列创建再拿到主线程渲染会黑屏。
    func originalImage(for asset: Asset, libraryName: String?) async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                // 上一个预览图先清掉，避免占地
                if let olds = try? FileManager.default.contentsOfDirectory(at: Self.previewPhotoDirectory,
                                                                          includingPropertiesForKeys: nil) {
                    for old in olds { try? FileManager.default.removeItem(at: old) }
                }
                guard let url = self.downloadLocked(session: self.photoSession,
                                                    fileName: asset.fileName,
                                                    libraryName: libraryName,
                                                    to: Self.previewPhotoDirectory,
                                                    expected: asset.byteSize,
                                                    progress: nil),
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Self.decodeOriginal(source, asset: asset))
            }
        }
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
