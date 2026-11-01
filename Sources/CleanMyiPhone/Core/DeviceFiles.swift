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
            // 必须真的关掉 AFC 连接再丢引用：只把指针置 nil，设备侧的连接还挂着，
            // 「重抓相册库」时就会变成「App 两条 AFC + helper 一条」抢同一根管子。
            if let api, let afc { api.closeAFC(afc) }
            pathIndex.removeAll()
            afc = nil
            api = nil
            device = nil
            error = nil
        }
    }

    private let queue = DispatchQueue(label: "cmi.devicefiles", qos: .utility)
    private let photoSession = Session()

    /// 预览专用通道：**独立的 AFC 会话 + 独立的串行队列**。
    /// 共用一条的话，首次进照片页那串缩略图（每个都要建 /DCIM 名字索引、下整份原图）
    /// 会把队列顶满，预览要排在它们后面 —— 界面上就是"只有转圈，一个字节都没有"。
    /// 建不起第二条会话（设备只答应一条）时 `downloadByDevicePath` 会自动回退共用通道。
    private let previewQueue = DispatchQueue(label: "cmi.devicefiles.preview", qos: .userInitiated)
    private let previewSession = Session()

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
        previewQueue.sync { previewSession.reset() }
        previewChannelBroken = false
    }

    // MARK: - 单个文件下载

    /// 一次下载的结果：除了文件，还带回**设备自己报的真实大小**（AFC 的 st_size），
    /// 上层要判「下没下全」只认它 —— PTP 的 `byteSize` 对很多文件是偏的。
    struct Downloaded {
        let url: URL
        let received: Int64
        let plan: Int64
    }

    func download(fileName: String,
                  libraryName: String? = nil,
                  to directory: URL,
                  priority: Bool = false,
                  progress: ((Int64) -> Void)? = nil) async -> URL? {
        lastError = nil
        // priority（预览）：走自己的队列和会话 —— 名字匹配第一次要先建 /DCIM 索引，
        // 排在整屏缩略图后面就是"打开了却没反应"。
        let session = priority ? previewSession : photoSession
        let runQueue = priority ? previewQueue : queue
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            runQueue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                let hit = self.downloadLocked(session: session,
                                              fileName: fileName,
                                              libraryName: libraryName,
                                              to: directory,
                                              priority: priority,
                                              progress: progress)
                self.lastError = session.error
                continuation.resume(returning: hit?.url)
            }
        }
    }

    private func downloadLocked(session: Session,
                                fileName: String,
                                libraryName: String?,
                                to directory: URL,
                                expected: Int64 = 0,
                                priority: Bool = false,
                                progress: ((Int64) -> Void)?) -> Downloaded? {
        // 预览在等通道，这次请求又不带优先级 → 直接让路。
        // 必须放在 prepare/buildIndex 之前：首次建 /DCIM 索引要枚举几千个文件，
        // 让路要排在它前面才有意义。
        if !priority, isPreviewWaiting() {
            previewWaitLock.lock(); previewYielded += 1; previewWaitLock.unlock()
            return nil
        }
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
        // 设备侧真实大小（st_size）。PTP 的 `byteSize` 只当兜底：
        // 它对不少文件是偏大的，拿它当「读够了没有」的判据会让读循环空转 4 秒，
        // 明明已经读完的文件被上层判成「下载不完整」直接删掉。
        let deviceSize = api.entrySize(afc, path: remote)
        let plan = deviceSize > 0 ? deviceSize : expected
        if FileManager.default.fileExists(atPath: local.path) {
            let onDisk = (try? FileManager.default.attributesOfItem(atPath: local.path))?[.size] as? Int64 ?? 0
            if plan <= 0 || onDisk >= plan { return Downloaded(url: local, received: onDisk, plan: plan) }
            try? FileManager.default.removeItem(at: local)   // 上次留的半截，重下
        }

        guard let ref = try? api.openFile(afc, path: remote) else {
            session.error = "打不开 \(remote)"
            return nil
        }
        defer { api.closeFile(afc, ref) }

        try? FileManager.default.removeItem(at: local)
        FileManager.default.createFile(atPath: local.path, contents: nil)
        // 原图 / 原视频的落盘：逐份登记，崩溃那一刻也删得掉
        TraceRegistry.registerTrace(local)
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
            let reachedPlan = plan > 0 && received >= plan
            if api.lastReadStatus == 0 && (reachedPlan || plan == 0) {
                stalled += 1
                if stalled > 3 { break }        // 连续 3 拍空读（60 ms）才认尾
                usleep(20_000)
                continue
            }
            stalled += 1
            if stalled > 200 { break }          // 真·读不动了（4 秒）才放弃
            usleep(20_000)
        }
        return Downloaded(url: local, received: received, plan: plan)
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

    /// 拿一次令牌：调用方自己轮询 `isPreviewCancelled(_:)`，
    /// 用来打断 IC 那条不可取消的下载（它没有自己的取消通路）。
    func previewToken() -> Int { currentPreviewEpoch() }

    func isPreviewCancelled(_ token: Int) -> Bool { currentPreviewEpoch() != token }

    // MARK: - 预览优先

    /// 预览正在等通道：缩略图请求这时候**主动让路**（立刻返回 nil）。
    /// 这不是为了第二条 AFC 会话 —— 那是另一层保险；这一层是兜底：
    /// 设备只答应一条会话时预览只能和缩略图共用队列，靠让路把队列瞬间排空，
    /// 否则一次预览要排在整屏几十个小请求后面，"只有转圈没有字节"又回来了。
    private let previewWaitLock = NSLock()
    private var previewWaiting = false
    private var previewYielded = 0

    func setPreviewWaiting(_ waiting: Bool) {
        previewWaitLock.lock(); previewWaiting = waiting; previewWaitLock.unlock()
        Self.trace("preview priority \(waiting ? "on" : "off")")
    }

    private func isPreviewWaiting() -> Bool {
        previewWaitLock.lock(); defer { previewWaitLock.unlock() }
        return previewWaiting
    }

    /// 让路期间有没有缩略图请求被放弃（取一次并清零）。
    /// 有的话预览结束后要让格子重新请求一遍，不然那几格会一直空着。
    func takePreviewYielded() -> Bool {
        previewWaitLock.lock(); defer { previewWaitLock.unlock() }
        let had = previewYielded > 0
        previewYielded = 0
        return had
    }

    /// 诊断日志：CMI_DEBUG=1 时写 /tmp/cmi-app.log（不含照片内容）
    static func trace(_ line: String) {
        guard ProcessInfo.processInfo.environment["CMI_DEBUG"] != nil else { return }
        let url = URL(fileURLWithPath: "/tmp/cmi-app.log")
        let text = "[preview] " + line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    /// 一次按路径下载的结果。**把 received/planned 带回来**：
    /// 完整性只能拿这个判（AFC 的 st_size 是准的），
    /// 拿界面上的进度状态当基准会把「已经下完」误判成「取回不完整」。
    struct PathDownload {
        let url: URL
        let received: Int64
        let planned: Int64
    }

    /// 一次按路径下载的结局。三种要分开处理：
    /// - `success` 拿到了完整文件
    /// - `aborted` 用户换了目标（不要再回退重试，否则等于把作废白做了）
    /// - `fileFailed` 通道是通的，是路径打不开
    /// - `sessionFailed` 这条 AFC 通道建不起来（设备只答应一条会话时就是它）
    private enum PathOutcome {
        case success(PathDownload)
        case aborted
        case fileFailed(String)
        case sessionFailed
    }

    /// 预览通道建不起来（设备只答应一条 AFC 会话）之后就别再反复试：
    /// 每次重试都要先失败一次，预览开头会白等。`reset()` 会把它清掉。
    private var previewChannelBroken = false

    func downloadByDevicePath(_ remotePaths: [String],
                              to directory: URL,
                              expected: Int64 = 0,
                              onProgress: ((Int64, Int64) -> Void)? = nil) async -> PathDownload? {
        let epoch = currentPreviewEpoch()
        let started = Date()
        // 1) 预览专用通道：视频是几百 MB 的整份下载，
        //    挤在缩略图那条串行队列后面会等整屏小请求，界面就是"只有转圈没有字节"。
        if !previewChannelBroken {
            Self.trace("start channel=preview paths=\(remotePaths.first ?? "-")")
            switch await runPathDownload(remotePaths, to: directory, expected: expected,
                                         onProgress: onProgress,
                                         session: previewSession, queue: previewQueue, epoch: epoch) {
            case .success(let hit):
                lastError = nil
                Self.trace("ok channel=preview \(hit.received)/\(hit.planned)B "
                           + String(format: "%.2fs", Date().timeIntervalSince(started)))
                return hit
            case .aborted:
                Self.trace("aborted channel=preview")
                return nil
            case .fileFailed(let message):
                lastError = message
                Self.trace("fileFailed channel=preview \(message)")
                return nil
            case .sessionFailed:
                // 设备只答应一条 AFC 会话 → 以后都走共用通道。这条会排在缩略图后面，
                // 但不会比改动前更差。
                previewChannelBroken = true
                Self.trace("preview channel FAILED → fallback to shared queue")
            }
        } else {
            Self.trace("start channel=shared(broken) paths=\(remotePaths.first ?? "-")")
        }
        // 2) 回退：共用通道
        switch await runPathDownload(remotePaths, to: directory, expected: expected,
                                     onProgress: onProgress,
                                     session: photoSession, queue: queue, epoch: epoch) {
        case .success(let hit):
            lastError = nil
            return hit
        case .aborted:
            return nil
        case .fileFailed(let message):
            lastError = message
            return nil
        case .sessionFailed:
            return nil
        }
    }

    private func runPathDownload(_ remotePaths: [String],
                                 to directory: URL,
                                 expected: Int64,
                                 onProgress: ((Int64, Int64) -> Void)?,
                                 session: Session,
                                 queue: DispatchQueue,
                                 epoch: Int) async -> PathOutcome {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: .sessionFailed); return }
                let t0 = Date()
                do { try session.prepare() } catch {
                    session.error = "准备失败：\(error.localizedDescription)"
                    Self.trace("prepare failed: \(error.localizedDescription)")
                    continuation.resume(returning: .sessionFailed)
                    return
                }
                Self.trace("prepared in " + String(format: "%.2fs", Date().timeIntervalSince(t0)))
                guard let api = session.api, let afc = session.afc else {
                    session.error = "AFC 未就绪"
                    continuation.resume(returning: .sessionFailed)
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
                    var firstChunk = false
                    while true {
                        if self.currentPreviewEpoch() != epoch {
                            aborted = true
                            break
                        }
                        if let chunk = api.readChunk(afc, ref) {
                            if !firstChunk {
                                firstChunk = true
                                Self.trace("first chunk \(received + Int64(chunk.count))B "
                                           + String(format: "%.2fs", Date().timeIntervalSince(t0)))
                            }
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
                            continuation.resume(returning: .aborted)
                            return
                        }
                        continue
                    }
                    if received > 0 {
                        // 只有「读到计划字节数」才走到这里（complete 已校验），
                        // 把真实数字一起带回去，调用方不用再猜
                        continuation.resume(returning: .success(Self.PathDownload(url: local,
                                                                                  received: received,
                                                                                  planned: plan)))
                        return
                    }
                }
                session.error = "按库里的路径打不开 \(remotePaths.first ?? "-")"
                continuation.resume(returning: .fileFailed(session.error ?? "打不开"))
            }
        }
    }

    // MARK: - 网格缩略图（AFC 读原图 → ImageIO 降采样）

    /// 缩略图缓存目录。
    /// **权限 0700**：里面是照片的缩小副本，同机其他账户不该能读。
    static var thumbDirectory: URL {
        let base = TraceRegistry.dataDirectory
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
        let url = thumbCacheURL(fileName: fileName, maxPixel: maxPixel)
        if (try? result.write(to: url)) != nil {
            // 逐张登记：崩溃那一刻才删得掉（信号上下文里拿不到目录列表）
            TraceRegistry.registerTrace(url)
        }
        return result
    }

    /// 清掉所有「原图/原视频」级别的一次性落盘（只清临时目录，不动缩略图缓存）。
    /// 退出/启动用的那一套在 `TraceRegistry.purgeAll()`，这里是「关预览」「换目标」时的小清理。
    static func purgeTransientFiles() {
        emptyDirectory(rawCacheDirectory)
        emptyDirectory(FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanmyiphone-preview", isDirectory: true))
        emptyDirectory(rawCacheDirectory.appendingPathComponent("preview", isDirectory: true))
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

    // MARK: - 设备端缩略图缓存（最快的一条路）

    /// 设备自己维护的缩略图缓存，iMazing 也是直接读这一套
    /// （`imazing-reverse/FILESYSTEM.md` 里的 `/PhotoData/Thumbnails/V2`）。
    ///
    /// 布局（iOS 26.7 实测）：
    /// ```
    /// /PhotoData/Thumbnails/V2/<ZDIRECTORY>/<ZFILENAME>/5005.JPG
    ///   例：.../V2/DCIM/109APPLE/IMG_9570.HEIC/5005.JPG   33,052 B   读取 3 ms
    ///       .../V2/DCIM/109APPLE/IMG_9810.MP4 /5005.JPG   57,625 B   读取 4 ms
    /// ```
    /// 注意 `ZDIRECTORY` 本身就是 `DCIM/109APPLE` 这个带前缀的形式（iCloud 那批是
    /// `PhotoData/PhotoCloudSharingData/...`），和 `V2/` 下的一二级目录一一对应 ——
    /// **不要再自己拼一个 `DCIM/` 上去**，那样会变成 `V2/DCIM/DCIM/109APPLE`。
    ///
    /// 照片和视频都有，一张只有 14–86 KB。对比原来"问 PTP（1.5 秒超时、串行）"或
    /// "下整份原图（DNG 能到 72 MB）"，这条路是 3–4 毫秒/张 —— 缩略图慢就是慢在没走这里。
    func deviceThumbnail(directory: String?, fileName: String) async -> Data? {
        let epoch = currentEpoch()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                guard self.currentEpoch() == epoch else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: self.deviceThumbnailLocked(directory: directory,
                                                                         fileName: fileName))
            }
        }
    }

    private func deviceThumbnailLocked(directory: String?, fileName: String) -> Data? {
        do { try photoSession.prepare() } catch { return nil }
        guard let api = photoSession.api, let afc = photoSession.afc else { return nil }

        var dirs: [String] = []
        if let directory {
            let clean = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !clean.isEmpty { dirs.append(clean) }
        }
        // 库还没到 / 目录名对不上时的兜底：从 /DCIM 名字索引反查属于哪个 APPLE 文件夹
        if dirs.isEmpty, let path = photoSession.pathIndex[fileName] {
            let parts = path.split(separator: "/")        // ["", "DCIM", "109APPLE", name]
            if parts.count >= 3 {
                let folder = String(parts[parts.count - 2])
                dirs.append("DCIM/\(folder)")
            }
        }
        guard !dirs.isEmpty else { return nil }

        for dir in dirs {
            let itemPath = "/PhotoData/Thumbnails/V2/\(dir)/\(fileName)"
            // 先按最常见的编号直取，省掉一次 listDirectory
            for leaf in ["5005.JPG", "5003.JPG", "5007.JPG"] {
                if let data = try? api.readFile(afc, path: "\(itemPath)/\(leaf)", limit: 4 << 20),
                   !data.isEmpty {
                    return data
                }
            }
            // 编号不是这几种：列一次目录，取最大的那张 JPEG
            guard let leaves = try? api.listDirectory(afc, path: itemPath), !leaves.isEmpty else { continue }
            var best: (name: String, size: Int64) = ("", 0)
            for leaf in leaves where leaf.uppercased().hasSuffix(".JPG") {
                let size = api.entrySize(afc, path: "\(itemPath)/\(leaf)")
                if size > best.size { best = (leaf, size) }
            }
            if best.size > 0,
               let data = try? api.readFile(afc, path: "\(itemPath)/\(best.name)", limit: 4 << 20),
               !data.isEmpty {
                return data
            }
        }
        return nil
    }

    private func thumbnailDataLocked(asset: Asset, libraryName: String?, maxPixel: Int) -> Data? {
        let cached = Self.thumbCacheURL(fileName: asset.fileName, maxPixel: maxPixel)
        if let data = try? Data(contentsOf: cached), !data.isEmpty { return data }

        // 视频不在网格里拉原文件，太贵
        guard asset.kind == .photo else { return nil }
        guard let hit = downloadLocked(session: photoSession,
                                       fileName: asset.fileName,
                                       libraryName: libraryName,
                                       to: Self.rawCacheDirectory,
                                       expected: asset.byteSize,
                                       priority: false,
                                       progress: nil) else { return nil }
        let url = hit.url
        defer { try? FileManager.default.removeItem(at: url) }

        // 完整性只认 AFC 报的设备真实大小（`hit.plan`）。
        // 以前这里拿 PTP 的 `asset.byteSize` 比：那个数对不少文件偏大，
        // 于是「其实已经读完」的图被判成「下载不完整」删掉、格子永远空着。
        if hit.plan > 0, hit.received < hit.plan {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: cached)
            lastError = "下载不完整 \(hit.received)/\(hit.plan)"
            return nil
        }
        if hit.received == 0 {
            try? FileManager.default.removeItem(at: url)
            lastError = "取回 0 字节"
            return nil
        }

        guard let data = Self.downsampleJPEG(url, maxPixel: maxPixel) else {
            // 解不出来（半截图）就把缓存清掉，避免一直花屏
            try? FileManager.default.removeItem(at: cached)
            return nil
        }
        try? data.write(to: cached)
        TraceRegistry.registerTrace(cached)
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
                guard let hit = self.downloadLocked(session: self.photoSession,
                                                    fileName: asset.fileName,
                                                    libraryName: libraryName,
                                                    to: Self.previewPhotoDirectory,
                                                    expected: asset.byteSize,
                                                    priority: true,
                                                    progress: nil),
                      let source = CGImageSourceCreateWithURL(hit.url as CFURL, nil) else {
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
