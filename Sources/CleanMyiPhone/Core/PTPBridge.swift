import AppKit
import ImageCaptureCore

/// 真机通道：ImageCaptureCore（PTP）。
/// 枚举、缩略图、元数据、删除都在这里，不走任何外部进程。
final class PTPBridge: NSObject, DeviceSource {

    let displayName = "iPhone"
    var supportsDeletion = true

    /// 设备出现/消失
    var onDevice: ((DeviceSnapshot?) -> Void)?
    /// 目录更新（增量回调，可能多次），第二个参数是 0–1 的进度
    var onCatalog: (([Asset], Double) -> Void)?
    /// 目录枚举完成（只发一次）——进度要等这个才能进下一段
    var onCatalogFinished: (() -> Void)?
    var onError: ((String) -> Void)?

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    /// 上传探针的回调落点（一次一条）
    private var uploadResult: ((String) -> Void)?

    private let lock = NSLock()
    private var filesByID: [String: ICCameraFile] = [:]
    /// 设备端推过来的缩略图（照片 + 视频都有）
    private var receivedThumbs: [String: NSImage] = [:]
    private var assetsByID: [String: Asset] = [:]
    private var started = false
    private var catalogFinishSent = false

    override init() {
        super.init()
        let raw = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: raw) ?? .camera
        browser.delegate = self
    }

    // MARK: - DeviceSource

    func load() async throws -> [Asset] {
        start()
        if let camera, camera.contentCatalogPercentCompleted == 0 {
            // 会话刚建立时内容目录可能还在拉，给一点时间再读
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return snapshot()
    }

    private var reenumerateAt: Date = .distantPast

    /// 正在等设备回缩略图的请求（id → 一次性回填）
    private var thumbWaiters: [String: ResumeOnce] = [:]
    /// 设备端缩略图连续失败几次就关掉这条捷径，别让每张图都陪跑超时
    private var thumbTimeouts = 0
    private var thumbCircuitOpen = false
    private var thumbCircuitOpenedAt: Date?

    func thumbnail(for asset: Asset, maxPixel: Int) async -> NSImage? {
        // 1) 已经收到过的
        if let image = lock.withLock({ receivedThumbs[asset.id] }) { return image }
        guard let file = lock.withLock({ filesByID[asset.id] }) else {
            reenumerateIfNeeded()
            return nil
        }
        // 2) 框架自己缓存的那张
        if let cg = file.thumbnail {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }

        // 设备端缩略图这条路试了几次都不回，就先让开，直接走 AFC
        if lock.withLock({ thumbCircuitOpen }) {
            // 熔断是「暂时别试」，不是永久关闭：30 秒后放一次请求进去探路。
            // 否则一次设备抖动就会让整屏**视频**永久空白 —— 视频只有这一条路。
            let cooled = lock.withLock { () -> Bool in
                guard thumbCircuitOpen, let opened = thumbCircuitOpenedAt,
                      Date().timeIntervalSince(opened) > 30 else { return false }
                thumbCircuitOpen = false
                thumbTimeouts = 0
                thumbCircuitOpenedAt = nil
                return true
            }
            if !cooled { return nil }
        }

        // 3) **主动向设备要**。iMazing 就是这么做的：
        //    `-[ICCameraItem requestThumbnail]` 没有 completion，
        //    结果通过 `cameraDevice:didReceiveThumbnail:forItem:error:` 回来，
        //    所以这里挂一个等待者 + 超时。
        let image: NSImage? = await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            let once = ResumeOnce(continuation)
            lock.lock()
            thumbWaiters[asset.id] = once
            lock.unlock()

            let started = Date()
            // 先要**大尺寸**缩略图：ICImageSourceThumbnailMaxPixelSize 会请求比
            // EXIF 内嵌图更大的版本（内嵌的往往只有 160×120，拿到网格里就是糊的）。
            // 注意它不能和 imageSourceShouldCache 同时用，后者会把这个键直接忽略。
            file.requestThumbnailData(
                options: [ICCameraItemThumbnailOption.imageSourceThumbnailMaxPixelSize: 800]
            ) { [weak self] data, error in
                guard let self else { return }
                if let data, let img = NSImage(data: data) {
                    self.finishThumbnail(id: asset.id, image: img)
                    return
                }
                Self.debugThumbLog("大图缩略图失败 \(asset.fileName) \(error?.localizedDescription ?? "-")，退回内嵌图")
                // 退一步：要内嵌的 EXIF 小图（快，但会糊），同时触发 delegate 那条路
                file.requestThumbnail()
                file.requestThumbnailData(options: nil) { [weak self] data2, _ in
                    guard let self else { return }
                    if let data2, let img = NSImage(data: data2) {
                        self.finishThumbnail(id: asset.id, image: img)
                    }
                }
            }
            // 超时按种类给（原来一律 1.5 秒，太短）：刚进照片页时设备还在枚举，
            // 几百 KB 的缩略图走 PTP 单流经常要两三秒才回来。1.5 秒一超、连续三次
            // 就熔断整条捷径，之后所有格子（尤其是只有这一条路的视频）永远空白。
            // 照片还有 AFC 兜底，等 3 秒就够了；视频没有别的路，多给一点。
            let wait: TimeInterval = asset.kind == .video ? 8 : 3
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                if !once.claimed {
                    Self.debugThumbLog("超时 \(asset.fileName) \(Int(Date().timeIntervalSince(started) * 1000))ms")
                    self.noteThumbFailure()
                }
                self.finishThumbnail(id: asset.id, image: nil)
            }
        }
        return image
    }

    /// 连续失败 8 次才把设备端缩略图这条捷径关掉。
    /// 阈值 3 太容易踩到：设备忙起来前三个请求就会超时，之后整屏都是空的。
    private func noteThumbFailure() {
        lock.lock()
        thumbTimeouts += 1
        if thumbTimeouts >= 8 {
            thumbCircuitOpen = true
            thumbCircuitOpenedAt = Date()
            Self.debugThumbLog("设备端缩略图连续失败 \(thumbTimeouts) 次，本次会话不再尝试")
        }
        lock.unlock()
    }

    private func noteThumbSuccess() {
        lock.lock()
        thumbTimeouts = 0
        lock.unlock()
    }

    /// 回填等待者（只回一次）并清掉等待表
    private func finishThumbnail(id: String, image: NSImage?) {
        lock.lock()
        let waiter = thumbWaiters.removeValue(forKey: id)
        if let image { receivedThumbs[id] = image }
        lock.unlock()
        guard let waiter else { return }
        if let image {
            waiter.resume(image)
        } else {
            waiter.resume(nil)
        }
    }

    /// 用 ImageCaptureCore 自己的下载接口取**原始文件**。
    /// 它按设备端的对象句柄取，不需要我们把文件名猜对 ——
    /// 之前「DCIM 里找不到」就是因为拿 PTP 的名字去 AFC 的目录索引里匹配，注定要错。
    ///
    /// `isCancelled`：IC 的下载没有可用的取消通路，只靠 60 秒兜底太久。
    /// 调用方（预览）换目标 / 关预览时传进来，这里 0.2 秒问一次，一过期就掐掉。
    func downloadOriginal(for asset: Asset,
                          to directory: URL,
                          onProgress: ((Int64, Int64) -> Void)? = nil,
                          onFinished: ((Int64, Int64) -> Void)? = nil,
                          isCancelled: (() -> Bool)? = nil) async -> URL? {
        guard let file = lock.withLock({ filesByID[asset.id] }) else {
            DeviceFiles.trace("IC 没有这条资产：\(asset.fileName)")
            reenumerateIfNeeded()
            return nil
        }
        let name = asset.fileName
        DeviceFiles.trace("IC download start \(name)")
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            var finished = false
            let finish: (URL?) -> Void = { url in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: url)
            }
            // 覆盖选项在这个 SDK 里只出现在文档注释里，没有对外常量；自己先删旧文件
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            let options: [ICDownloadOption: Any] = [
                ICDownloadOption.downloadsDirectoryURL: directory,
                ICDownloadOption.saveAsFilename: name
            ]
            var timer: Timer?
            var cancelTimer: Timer?
            var progressRef: Progress?
            func stopTimers() {
                timer?.invalidate()
                cancelTimer?.invalidate()
            }
            progressRef = file.requestDownload(options: options) { filename, error in
                stopTimers()
                if let error {
                    Self.debugThumbLog("IC 下载失败 \(name)：\(error.localizedDescription)")
                    finish(nil)
                    return
                }
                if let filename, !filename.isEmpty {
                    let url = URL(fileURLWithPath: filename)
                    if FileManager.default.fileExists(atPath: url.path) {
                        if let progressRef, let onFinished {
                            onFinished(progressRef.completedUnitCount, progressRef.totalUnitCount)
                        }
                        finish(url)
                        return
                    }
                }
                let fallback = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: fallback.path) else { finish(nil); return }
                if let progressRef, let onFinished {
                    onFinished(progressRef.completedUnitCount, progressRef.totalUnitCount)
                }
                finish(fallback)
            }
            // 有进度就报给界面：让用户看到"已取回 40%"，而不是一句干等的提示
            if let progressRef, let onProgress {
                timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
                    onProgress(progressRef.completedUnitCount, progressRef.totalUnitCount)
                    if progressRef.isFinished || progressRef.isCancelled { t.invalidate() }
                }
            }
            // 换目标 / 关预览：0.2 秒内掐断，别让旧视频继续独占 PTP 单流
            if let isCancelled {
                cancelTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
                    guard isCancelled() else { return }
                    t.invalidate()
                    progressRef?.cancel()
                    Self.debugThumbLog("IC 下载被作废 \(name)")
                    let fallback = directory.appendingPathComponent(name)
                    try? FileManager.default.removeItem(at: fallback)
                    finish(nil)
                }
            }
            // 60 秒兜底：首屏刚打开时设备可能在忙枚举，给足时间；超过就报错
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                stopTimers()
                finish(nil)
            }
        }
    }

    /// 内容目录映射空了就请设备重发一次（10 秒内只发一次，避免刷屏）
    private func reenumerateIfNeeded() {
        guard Date().timeIntervalSince(reenumerateAt) > 10 else { return }
        reenumerateAt = Date()
        // 这个 SDK 没有「重新枚举」的请求方法，只能把浏览器停一下再起
        browser.stop()
        browser.start()
    }

    private func requestThumbnail(_ file: ICCameraFile,
                                  options: [ICCameraItemThumbnailOption: Any],
                                  timeout: TimeInterval) async -> NSImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            let once = ResumeOnce(continuation)
            file.requestThumbnailData(options: options) { data, _ in
                guard once.claim() else { return }
                if let data, let image = NSImage(data: data) {
                    once.resume(image)
                } else {
                    once.resume(nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                once.resume(nil)
            }
        }
    }

    /// 探针用：分别试「框架自带缩略图」和三种 requestThumbnailData 参数，把结果原样带出来
    func debugThumbnail(for asset: Asset, maxPixel: Int?) async -> (Int, String) {
        guard let file = lock.withLock({ filesByID[asset.id] }) else { return (0, "no file") }
        if let cg = file.thumbnail {
            return (cg.width * cg.height, "builtin \(cg.width)x\(cg.height)")
        }
        var options: [ICCameraItemThumbnailOption: Any] = [:]
        if let maxPixel {
            options[ICCameraItemThumbnailOption(rawValue: "kCGImageSourceThumbnailMaxPixelSize")] = maxPixel
        }
        return await withCheckedContinuation { (c: CheckedContinuation<(Int, String), Never>) in
            let boxLock = NSLock()
            var done = false
            let finish: (Int, String) -> Void = { bytes, note in
                boxLock.lock()
                let first = !done
                done = true
                boxLock.unlock()
                if first { c.resume(returning: (bytes, note)) }
            }
            file.requestThumbnailData(options: options) { data, error in
                finish(data?.count ?? 0, error.map { String(describing: $0) } ?? "no-error")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(-1, "timeout") }
        }
    }

    /// 一批删除最多等多久。
    ///
    /// 设备锁屏 / 被「访达」「照片」抢走 / 通道半死的时候，`requestDeleteFiles` 的
    /// completion **可能永远不来**（不是报错，是不回）。没这道闸，界面上那个
    /// 「正在删除」会一直转圈，用户只能强退 —— 2026-11 用户说的「删着删着像崩了」
    /// 就是这种。到点就收尾，并把这一批按「没回执」逐条报给界面。
    static let deleteTimeout: TimeInterval = 45

    func delete(ids: [Asset.ID]) async -> DeleteBatchResult {
        var report = DeleteBatchResult()

        // 设备侧会话会自己消失（iPhone 锁屏 / 空闲太久 / 被访达和照片 App 抢走），
        // 这时 `camera` 是 nil，整批删除会一项都没试就全部失败 —— 用户看到的就是
        // 「成功 0 项，全都失败，设备未连接」（2026-11-01 现场）。别再让用户自己去
        // 重启 App 或拔插数据线，这里先自己做一次完整重连再重试。
        guard let camera = await cameraOrReconnect(timeout: 8) else {
            report.failed = ids.map { ($0, "设备未连接（解锁 iPhone 后重试）") }
            return report
        }
        // 会话刚重建时文件表还在填，给几秒收尾；空表会让下面每条都判成「设备上找不到」
        await waitForFiles(timeout: 3)

        var files: [ICCameraFile] = []
        var idByFile: [ObjectIdentifier: Asset.ID] = [:]
        var missingIDs = Set<Asset.ID>()

        lock.lock()
        for id in ids {
            if let file = filesByID[id] {
                files.append(file)
                idByFile[ObjectIdentifier(file)] = id
            } else {
                missingIDs.insert(id)
                report.failed.append((id, "设备上已找不到这个文件（可能已经被删掉）"))
            }
        }
        lock.unlock()

        guard !files.isEmpty else { return report }

        var succeeded: [Asset.ID] = []
        var failureByID: [Asset.ID: String] = [:]
        var batchError: String?
        var timedOut = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = VoidOnce(continuation)
            let boxLock = NSLock()
            var finished = false
            let finish: (Bool) -> Void = { isTimeout in
                boxLock.lock()
                let first = !finished
                finished = true
                boxLock.unlock()
                guard first else { return }
                if isTimeout { timedOut = true }
                once.finish()
            }

            _ = camera.requestDeleteFiles(files, deleteFailed: { (dict: [ICDeleteError: ICCameraItem]) in
                // 设备**逐条**报到失败的都记下来：这是「哪些没删掉、为什么」的唯一来源
                for (key, item) in dict {
                    guard let id = idByFile[ObjectIdentifier(item)] else { continue }
                    failureByID[id] = Self.message(forDelete: key)
                }
            }, completion: { result, error in
                for item in result[.successful] ?? [] {
                    if let id = idByFile[ObjectIdentifier(item)] { succeeded.append(id) }
                }
                if let error, !error.localizedDescription.isEmpty {
                    batchError = error.localizedDescription
                }
                finish(false)
            })

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.deleteTimeout) { finish(true) }
        }

        // 既不在成功名单、也没有逐条原因的，就是「设备没回执」的那批。
        // 以前这里会把它们静默丢掉（界面只剩一条总的 error），现在每条都要有话说。
        let succeededSet = Set(succeeded)
        for id in ids where !succeededSet.contains(id) && !missingIDs.contains(id) {
            guard failureByID[id] == nil else { continue }
            if timedOut {
                failureByID[id] = "设备 \(Int(Self.deleteTimeout)) 秒没有回执（可能锁屏或通道断了），这一项没删成"
            } else {
                failureByID[id] = batchError.map { "设备报错：\($0)" }
                    ?? "设备没有回执，这一项没删成（可能被「照片」App 占用）"
            }
        }
        for (id, message) in failureByID {
            report.failed.append((id, message))
        }

        lock.lock()
        for id in succeeded {
            filesByID[id] = nil
            assetsByID[id] = nil
        }
        lock.unlock()
        publish()

        report.succeeded = succeeded
        report.timedOut = timedOut
        return report
    }

    // MARK: - 上传探针（能不能把文件写回设备）

    /// 试 `ICCameraDevice.requestUploadFile`。
    ///
    /// 头文件里这个方法被标成：
    /// `IC_DEPRECATED("Sandbox restrictions prohibit writing directly to device hardware", macos(10.4,14.0))`
    /// —— 只是 deprecated 不是 unavailable，所以还有必要实测一次：
    /// 本 App 是 ad-hoc 签名的非沙盒程序，可能不受 Apple 那把锁影响。
    /// 结果决定「压缩版能不能自动回手机相册」，是整条方案的最后一块拼图。
    func probeUpload(fileURL: URL, timeout: TimeInterval = 20) async -> String {
        guard let camera else { return "设备没连上" }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            var finished = false
            let box = NSLock()
            let finish: (String) -> Void = { message in
                box.lock()
                let first = !finished
                finished = true
                box.unlock()
                if first { continuation.resume(returning: message) }
            }
            self.uploadResult = finish

            camera.requestUploadFile(fileURL,
                                     options: [:],
                                     uploadDelegate: self,
                                     didUploadSelector: #selector(PTPBridge.uploadDidFinish(_:error:contextInfo:)),
                                     contextInfo: nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                finish("超时：\(Int(timeout)) 秒没有回调（设备大概率不认这条命令）")
            }
        }
    }

    @objc private func uploadDidFinish(_ fileURL: URL,
                                       error: Error?,
                                       contextInfo: UnsafeMutableRawPointer?) {
        let sink = uploadResult
        uploadResult = nil
        if let error {
            sink?("失败：\(error.localizedDescription)")
        } else {
            sink?("成功：\(fileURL.lastPathComponent) 已上传")
        }
    }

    private static func message(forDelete key: ICDeleteError) -> String {
        let text = String(describing: key)
        if text.contains("ReadOnly") {
            return "设备只读（开了 iCloud 照片 / 优化存储时常见），只能在这台 iPhone 的「照片」里删"
        }
        if text.contains("Permission") || text.contains("Authoriz") {
            return "设备没给删除权限（解锁 iPhone 后重试）"
        }
        if text.contains("NotFound") {
            return "设备上已找不到这个文件（可能已经被删掉）"
        }
        if text.contains("Cancel") {
            return "设备取消了这次删除（多半是那一刻锁屏了）"
        }
        if text.contains("Unavailable") || text.contains("Disconnect") {
            return "设备中途断开（看一下数据线，解锁后重试）"
        }
        if text.contains("InvalidParam") {
            return "设备不接受这个删除请求"
        }
        if text.contains("Failed") {
            return "设备拒绝删除（这条可能正被「照片」App 或同步占用）"
        }
        return "删除失败：\(text)"
    }

    // MARK: - Session

    func start() {
        guard !started else { return }
        started = true
        browser.start()
    }

    /// 拿相机对象；拿不到就把浏览器**整个重置一遍**再等设备上来。
    ///
    /// 为什么需要：iPhone 锁屏 / 空闲太久 / 被访达或「照片」抢走时，设备侧会关掉
    /// PTP 会话，`camera` 变 nil。这时整批删除会一项都没试就全失败 ——
    /// 用户看到的就是「成功 0 项，全都失败，设备未连接」。
    ///
    /// 为什么是 `stop()` + `start()` 而不是只 `start()`：`start()` 有 `started` 守卫，
    /// **浏览器活着但会话死了**的时候它什么都不做，等于白等。先 `stop()` 把 `started`
    /// 清掉、`browser.stop()`，再 `start()` 才是一次真正的重连（这也是「拔插数据线
    /// 才有用」在 App 内的等价操作）。
    ///
    /// 只在主线程调用（`delete` ← `PurgeEngine` 是 @MainActor），IC 的 browser 要求主线程。
    private func cameraOrReconnect(timeout: TimeInterval) async -> ICCameraDevice? {
        if let camera { return camera }
        stop()
        try? await Task.sleep(nanoseconds: 300_000_000)   // 让 browser 真正停稳
        start()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let camera { return camera }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return camera
    }

    /// 文件表里有没有东西（同步读，配合 async 里的轮询用）
    private func filesAreReady() -> Bool {
        lock.withLock { !filesByID.isEmpty }
    }

    private func waitForFiles(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if filesAreReady() { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func stop() {
        browser.stop()
        started = false
        catalogFinishSent = false
        camera?.requestCloseSession()
        camera = nil
        lock.withLock {
            filesByID.removeAll()
            assetsByID.removeAll()
        }
        DispatchQueue.main.async { [weak self] in self?.onDevice?(nil) }
    }

    /// 设备内容目录拉完（只发一次）
    private func finishCatalog() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.catalogFinishSent else { return }
            self.catalogFinishSent = true
            self.onCatalogFinished?()
        }
    }

    // MARK: - Catalog

    private func snapshot() -> [Asset] {
        lock.withLock { Array(assetsByID.values) }
    }

    private func publish() {
        let assets = snapshot().sorted { $0.createdAt > $1.createdAt }
        let progress = Double(camera?.contentCatalogPercentCompleted ?? 0) / 100
        DispatchQueue.main.async { [weak self] in
            self?.onCatalog?(assets, progress)
        }
        if progress >= 0.999 { finishCatalog() }
    }

    private func ingest(_ items: [ICCameraItem]) {
        var changed = false
        lock.lock()
        for item in items {
            guard let file = item as? ICCameraFile else { continue }
            let asset = Self.makeAsset(from: file)
            filesByID[asset.id] = file
            if assetsByID[asset.id] != asset {
                assetsByID[asset.id] = asset
                changed = true
            }
        }
        lock.unlock()
        if changed { publish() }
    }

    private static func folderPath(for file: ICCameraFile) -> String {
        guard let parent = file.parentFolder?.name, !parent.isEmpty else { return "DCIM" }
        return "DCIM/\(parent)"
    }

    private static func assetID(fileName: String, folder: String) -> String {
        "\(fileName)|\(folder)"
    }

    private static func assetID(for file: ICCameraFile) -> String {
        assetID(fileName: file.name ?? "", folder: folderPath(for: file))
    }

    private static func makeAsset(from file: ICCameraFile) -> Asset {
        let name = file.name ?? "未命名"
        let folder = folderPath(for: file)
        let ext = (name as NSString).pathExtension.uppercased()
        let uti = file.uti ?? ""
        let isVideo = uti.contains("movie") || uti.contains("video")
            || ["MOV", "MP4", "M4V", "3GP", "AVI"].contains(ext)

        if ProcessInfo.processInfo.environment["CMI_DEBUG"] != nil {
            print("[ptp] \(name) | orig=\(file.originatingAssetID ?? "-") | group=\(file.groupUUID ?? "-") | burst=\(file.burstUUID ?? "-")")
        }

        var tags: MediaTag = []
        if file.burstUUID != nil { tags.insert(.burst) }
        if file.highFramerate { tags.insert(.slomo) }
        if file.timeLapse { tags.insert(.timelapse) }
        if file.groupUUID != nil { tags.insert(.live) }

        return Asset(
            id: assetID(fileName: name, folder: folder),
            fileName: name,
            folder: folder,
            byteSize: Int64(file.fileSize),
            createdAt: file.fileCreationDate ?? Date(timeIntervalSince1970: 0),
            kind: isVideo ? .video : .photo,
            tags: tags,
            pixelWidth: Int(file.width),
            pixelHeight: Int(file.height),
            duration: max(0, Double(file.duration))
        )
    }
}

// MARK: - Browser delegate

extension PTPBridge: ICDeviceBrowserDelegate {

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        self.camera = camera
        camera.delegate = self
        camera.requestOpenSession()

        let snapshot = DeviceSnapshot(
            id: camera.serialNumberString ?? camera.name ?? "device",
            name: camera.name ?? "iPhone",
            model: camera.productKind ?? "iPhone",
            isReady: false
        )
        DispatchQueue.main.async { [weak self] in self?.onDevice?(snapshot) }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard (device as? ICCameraDevice) === camera else { return }
        camera = nil
        lock.withLock {
            filesByID.removeAll()
            assetsByID.removeAll()
        }
        DispatchQueue.main.async { [weak self] in self?.onDevice?(nil) }
    }
}

// MARK: - Camera delegate

extension PTPBridge: ICCameraDeviceDelegate {

    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        guard error == nil, let camera = device as? ICCameraDevice else {
            if let error { onError?(error.localizedDescription) }
            return
        }
        ingest(camera.mediaFiles ?? [])
        publish()
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}

    func didRemove(_ device: ICDevice) {
        guard (device as? ICCameraDevice) === camera else { return }
        camera = nil
        DispatchQueue.main.async { [weak self] in self?.onDevice?(nil) }
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice else { return }
        ingest(camera.mediaFiles ?? [])
        publish()
    }

    /// 设备端缩略图这条路的诊断（写同一个 thumb-log.txt）
    static func debugThumbLog(_ line: String) {
        let base = TraceRegistry.dataDirectory
        DeviceFiles.makePrivateDirectory(base)
        let url = base.appendingPathComponent("thumb-log.txt")
        let text = "ic-thumb " + line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        ingest(device.mediaFiles ?? [])
        publish()
        finishCatalog()
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        ingest(items)
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        lock.lock()
        for item in items {
            guard let file = item as? ICCameraFile else { continue }
            let id = Self.assetID(for: file)
            assetsByID.removeValue(forKey: id)
            filesByID.removeValue(forKey: id)
        }
        lock.unlock()
        publish()
    }

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        ingest(items)
    }

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        ingest(camera.mediaFiles ?? [])
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    /// 告诉框架「这个文件的缩略图我需要」。
    /// iMazing 就实现了这一条（`cameraDevice:shouldGetThumbnailOfItem:`），
    /// 框架会在枚举时顺手把设备端缩略图（照片和视频都有，几百 KB）取回来，
    /// 比我们自己下几十 MB 的视频去抽帧快两个数量级。
    func cameraDevice(_ camera: ICCameraDevice,
                      shouldGetThumbnailOf item: ICCameraItem) -> Bool {
        return true
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?,
                      for item: ICCameraItem, error: (any Error)?) {
        if thumbnail == nil, let error {
            Self.debugThumbLog("didReceiveThumbnail 空：\(error.localizedDescription)")
        }
        guard let file = item as? ICCameraFile, let cg = thumbnail else { return }
        let id = Self.assetID(for: file)
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        lock.lock()
        receivedThumbs[id] = image
        let waiter = thumbWaiters.removeValue(forKey: id)
        lock.unlock()
        noteThumbSuccess()
        waiter?.resume(image)
        // 顺手落一份 480px JPEG，下次直接命中磁盘缓存
        if let name = file.name, !name.isEmpty {
            _ = DeviceFiles.writeThumbnailCache(cg, fileName: name, maxPixel: 480)
            Self.debugThumbLog("ok \(name) \(cg.width)x\(cg.height)")
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
                      for item: ICCameraItem, error: (any Error)?) {}

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

// MARK: - 只 finish 一次的续体

private final class VoidOnce {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<Void, Never>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume()
    }
}

// MARK: - 只 resume 一次的续体

final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<NSImage?, Never>

    init(_ continuation: CheckedContinuation<NSImage?, Never>) {
        self.continuation = continuation
    }

    var claimed: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }

    /// 只有一个调用者会真正回填，重入/超时都安全
    func resume(_ image: NSImage?) {
        guard claim() else { return }
        continuation.resume(returning: image)
    }
}
