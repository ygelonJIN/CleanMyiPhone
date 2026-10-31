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

    private let lock = NSLock()
    private var filesByID: [String: ICCameraFile] = [:]
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

    /// 哪条路真的能出图：0 = 还没试，1 = 内置缩略图，2 = 默认参数，3 = 指定分辨率
    private var workingStrategy = 0
    private var reenumerateAt: Date = .distantPast

    func thumbnail(for asset: Asset, maxPixel: Int) async -> NSImage? {
        // 这台设备上 requestThumbnailData 一律不回数据（要等超时），
        // 所以只取框架已经缓存好的那张 CGImage，拿不到就立刻交给 AFC 兜底。
        guard let file = lock.withLock({ filesByID[asset.id] }) else {
            reenumerateIfNeeded()
            return nil
        }
        guard let cg = file.thumbnail else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
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

    func delete(ids: [Asset.ID]) async -> (succeeded: [Asset.ID], failed: [(id: Asset.ID, message: String)]) {
        guard let camera else {
            return ([], ids.map { ($0, "设备未连接") })
        }

        var files: [ICCameraFile] = []
        var idByFile: [ObjectIdentifier: Asset.ID] = [:]
        var missing: [(Asset.ID, String)] = []

        lock.lock()
        for id in ids {
            if let file = filesByID[id] {
                files.append(file)
                idByFile[ObjectIdentifier(file)] = id
            } else {
                missing.append((id, "设备上已找不到这个文件"))
            }
        }
        lock.unlock()

        guard !files.isEmpty else { return ([], missing) }

        var succeeded: [Asset.ID] = []
        var failed: [(id: Asset.ID, message: String)] = missing

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = VoidOnce(continuation)
            _ = camera.requestDeleteFiles(files, deleteFailed: { (dict: [ICDeleteError: ICCameraItem]) in
                for (key, item) in dict {
                    let id = idByFile[ObjectIdentifier(item)] ?? "未知项"
                    failed.append((id, Self.message(forDelete: key)))
                }
            }, completion: { result, error in
                for item in result[.successful] ?? [] {
                    if let id = idByFile[ObjectIdentifier(item)] { succeeded.append(id) }
                }
                if let error, succeeded.isEmpty {
                    failed.append(("", error.localizedDescription))
                }
                once.finish()
            })
        }

        lock.lock()
        for id in succeeded {
            filesByID[id] = nil
            assetsByID[id] = nil
        }
        lock.unlock()
        publish()

        return (succeeded, failed)
    }

    private static func message(forDelete key: ICDeleteError) -> String {
        let text = String(describing: key)
        if text.contains("ReadOnly") { return "设备只读（多半是开了 iCloud 照片），只能在这台 iPhone 上删" }
        if text.contains("Failed") { return "设备拒绝删除" }
        return "删除失败：\(text)"
    }

    // MARK: - Session

    func start() {
        guard !started else { return }
        started = true
        browser.start()
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

    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?,
                      for item: ICCameraItem, error: (any Error)?) {}

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

private final class ResumeOnce {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<NSImage?, Never>

    init(_ continuation: CheckedContinuation<NSImage?, Never>) {
        self.continuation = continuation
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }

    func resume(_ image: NSImage?) {
        continuation.resume(returning: image)
    }
}
