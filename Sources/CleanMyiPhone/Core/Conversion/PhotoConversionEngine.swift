import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 批量转换引擎。
///
/// 并发模型：
/// - **下载串行**：AFC 是一条状态化的连接，多个读并发会把请求交错，反而更慢。
/// - **编码并行**：真正吃 CPU 的一段，`maxConcurrent` 个 worker。
/// - **写设备串行**：写的是压缩后的小文件，串行足够快。
/// - **改库一次**：整批只写一次 `Photos.sqlite`、只重启一次 `assetsd`。
///
/// 这样一批 100 张的瓶颈是 USB 下载，不是编码；也不会出现“每张都改一次库”。
final class PhotoConversionEngine: @unchecked Sendable {

    struct Progress: Sendable {
        let phase: String
        let completed: Int
        let total: Int
        let current: String
    }

    struct Result: Sendable {
        var records: [ConversionRecord] = []
        var failures: [(name: String, reason: String)] = []
        var skipped: [(name: String, reason: String)] = []
        var dbPath: String?
        var daemonRestarted = false
        var elapsed: TimeInterval = 0
    }

    private let api: MobileDeviceAPI
    private let device: UnsafeMutableRawPointer
    private let afc: UnsafeMutableRawPointer
    private let udid: String
    private let workDir: URL
    private let maxConcurrent: Int
    private let ownsSession: Bool

    init(udid: String, workDir: URL) throws {
        self.api = try MobileDeviceAPI.shared()
        self.device = try api.firstDevice(timeout: 10)
        self.ownsSession = !api.isSessionOpen
        try api.openSession(device)
        self.afc = try api.openAFC(device)
        self.udid = udid.isEmpty ? api.info(device).identifier : udid
        self.workDir = workDir
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        self.maxConcurrent = min(4, max(1, cores / 2))
    }

    deinit {
        api.closeAFC(afc)
        if ownsSession { api.stopSession(device) }
    }

    func run(items: [ConversionItem],
             profile: ConversionProfile,
             writeFiles: Bool = true,
             writeDB: Bool = true,
             restartDaemon: Bool = true,
             keepWorkDir: Bool = false,
             progress: @escaping (Progress) -> Void = { _ in },
             isCancelled: @escaping () -> Bool = { false }) -> Result {
        defer {
            if !keepWorkDir {
                try? FileManager.default.removeItem(at: workDir)
            }
        }
        let started = Date()
        var result = Result()
        let total = items.count
        var completed = 0

        let rawCount = items.filter(\.isRAW).count
        let workers = rawCount > 0 ? min(2, maxConcurrent) : maxConcurrent
        let chunkSize = max(4, workers * 2)

        var dirCache: [String: Set<String>] = [:]
        var usedNames: [String: Set<String>] = [:]

        for chunkStart in stride(from: 0, to: items.count, by: chunkSize) {
            if isCancelled() { break }
            let end = min(chunkStart + chunkSize, items.count)
            let chunk = Array(items[chunkStart..<end])

            // 1) 串行下载
            var downloaded: [(ConversionItem, URL)] = []
            for item in chunk {
                if isCancelled() { break }
                let ext = (item.fileName as NSString).pathExtension
                let local = workDir.appendingPathComponent(
                    "\(item.pk)-\(UUID().uuidString).\(ext.isEmpty ? "bin" : ext)")
                do {
                    let remote = remotePath(item)
                    // 必须把设备侧 st_size 传进去：expected=0 时 downloadFile 会在文件尾
                    // 空等 40 拍（0.8 秒/张），一批几百张就是几分钟白等。
                    let expected = api.entrySize(afc, path: remote)
                    let bytes = try api.downloadFile(afc, path: remote, to: local, expected: expected)
                    guard bytes > 0 else {
                        throw NSError(domain: "cmi.convert", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "下载 0 字节"])
                    }
                    downloaded.append((item, local))
                } catch {
                    result.failures.append((item.fileName, "下载失败：\(error.localizedDescription)"))
                }
            }

            // 2) 并行编码
            let lock = NSLock()
            var encoded: [(ConversionItem, URL, Int, Int, Int64)] = []
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "cmi.convert.encode", attributes: .concurrent)
            let semaphore = DispatchSemaphore(value: workers)

            for (item, local) in downloaded {
                group.enter()
                queue.async {
                    semaphore.wait()
                    defer {
                        semaphore.signal()
                        group.leave()
                    }
                    do {
                        let out = try self.encode(item: item, local: local, profile: profile)
                        let size = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size]
                            as? NSNumber)?.int64Value ?? 0
                        let dims = self.dimensions(of: out)
                        lock.lock()
                        encoded.append((item, out, dims.0, dims.1, size))
                        lock.unlock()
                    } catch {
                        lock.lock()
                        result.failures.append((item.fileName, "编码失败：\(error.localizedDescription)"))
                        lock.unlock()
                    }
                }
            }
            group.wait()
            encoded.sort { $0.0.pk < $1.0.pk }

            // 3) 串行写设备
            for (item, out, width, height, size) in encoded {
                if isCancelled() { break }
                let dir = item.directory
                var names = dirCache[dir] ?? Set((try? api.listDirectory(afc, path: "/" + dir)) ?? [])
                var used = usedNames[dir] ?? []

                let base = (item.fileName as NSString).deletingPathExtension
                var name = ""
                var index = 1
                while true {
                    let candidate = "\(base) (\(index)).\(profile.format.fileExtension)"
                    if !names.contains(candidate) && !used.contains(candidate) {
                        name = candidate
                        break
                    }
                    index += 1
                }

                let remote = "/" + dir + "/" + name
                do {
                    if writeFiles {
                        let data = try Data(contentsOf: out)
                        let written = try api.writeFile(afc, path: remote, data: data)
                        let deviceSize = api.entrySize(afc, path: remote)
                        guard written == Int64(data.count) else {
                            throw NSError(domain: "cmi.convert", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "写入字节数不对"])
                        }
                        guard deviceSize <= 0 || deviceSize == Int64(data.count) else {
                            throw NSError(domain: "cmi.convert", code: 3,
                                          userInfo: [NSLocalizedDescriptionKey: "设备回读大小不对"])
                        }
                    }

                    names.insert(name)
                    used.insert(name)
                    dirCache[dir] = names
                    usedNames[dir] = used

                    result.records.append(ConversionRecord(
                        originalPK: item.pk,
                        originalFileName: item.fileName,
                        originalUUID: item.uuid,
                        originalSize: item.byteSize,
                        newPK: 0,
                        newUUID: UUID().uuidString,
                        directory: dir,
                        newFileName: name,
                        newUTI: profile.format.utType.identifier,
                        newWidth: width,
                        newHeight: height,
                        newSize: size,
                        quality: Int((profile.clampedQuality * 100).rounded()),
                        isScreenshot: item.isScreenshot,
                        favorite: item.favorite
                    ))
                    completed += 1
                    progress(Progress(phase: writeFiles ? "写入" : "编码",
                                      completed: completed,
                                      total: total,
                                      current: item.fileName))
                } catch {
                    result.failures.append((item.fileName, "写设备失败：\(error.localizedDescription)"))
                }

                try? FileManager.default.removeItem(at: out)
            }

            for (_, local) in downloaded {
                try? FileManager.default.removeItem(at: local)
            }
        }

        if writeDB, !result.records.isEmpty {
            do {
                progress(Progress(phase: "改库", completed: completed, total: total,
                                  current: "\(result.records.count) 条"))
                // 批次可能跑了几分钟，开始时的快照已经旧了。
                // 改库前重新抓一份当前库，避免把期间新拍/新导入的照片覆盖掉。
                let freshDB = try fetchFreshDB()
                let nextPK = try nextPrimaryKey(dbPath: freshDB)
                for index in result.records.indices {
                    result.records[index].newPK = nextPK + index
                }
                let workDB = try ConversionDB.apply(dbPath: freshDB,
                                                    workDir: workDir,
                                                    records: result.records)
                result.dbPath = workDB.path

                let data = try Data(contentsOf: workDB)
                let temp = "/PhotoData/Photos.sqlite.new"
                try? api.removePath(afc, path: temp)
                let written = try api.writeFile(afc, path: temp, data: data)
                guard written == Int64(data.count) else {
                    throw NSError(domain: "cmi.convert", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "库写入字节数不对"])
                }
                try api.renamePath(afc, from: temp, to: "/PhotoData/Photos.sqlite")
                try? api.removePath(afc, path: "/PhotoData/Photos.sqlite-wal")
                try? api.removePath(afc, path: "/PhotoData/Photos.sqlite-shm")
            } catch {
                result.failures.append(("数据库", "写库失败：\(error.localizedDescription)"))
            }

            // 库已经写进去了；刷新失败只影响“现在能不能看到”，不影响数据。
            if restartDaemon, result.dbPath != nil {
                progress(Progress(phase: "重启相册", completed: completed, total: total,
                                  current: "assetsd"))
                do {
                    try PhotoDaemon.restartLibrary(udid: udid)
                    result.daemonRestarted = true
                } catch {
                    result.failures.append((
                        "相册刷新",
                        "写库成功，但相册没刷新：\(error.localizedDescription)。重启 iPhone 后生效"
                    ))
                }
            }
        }

        result.elapsed = Date().timeIntervalSince(started)
        return result
    }

    private func remotePath(_ item: ConversionItem) -> String {
        "/" + item.directory + "/" + item.fileName
    }

    /// 改库前重新抓一份当前库：批次可能跑了几分钟，期间用户拍的照片不能丢。
    private func fetchFreshDB() throws -> String {
        let dir = workDir.appendingPathComponent("fresh", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm"] {
            let remote = "/PhotoData/" + name
            let expected = api.entrySize(afc, path: remote)
            if expected <= 0 { continue }
            let local = dir.appendingPathComponent(name)
            let bytes = try api.downloadFile(afc, path: remote, to: local, expected: expected)
            if bytes <= 0 {
                throw NSError(domain: "cmi.convert", code: 9,
                              userInfo: [NSLocalizedDescriptionKey: "重新抓库失败：\(name)"])
            }
        }
        let path = dir.appendingPathComponent("Photos.sqlite").path
        guard FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "cmi.convert", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "当前库没抓到"])
        }
        return path
    }

    private func nextPrimaryKey(dbPath: String) throws -> Int {
        guard let db = SQLiteDB(path: dbPath, writable: false) else { return 1 }
        let fromKey = db.rows("SELECT MAX(Z_MAX) AS m FROM Z_PRIMARYKEY WHERE Z_ENT IN (1,3)")
            .first?.int("m") ?? 0
        let fromAsset = db.rows("SELECT MAX(Z_PK) AS m FROM ZASSET").first?.int("m") ?? 0
        let fromAZAA = db.rows("SELECT MAX(Z_PK) AS m FROM ZADDITIONALASSETATTRIBUTES")
            .first?.int("m") ?? 0
        return max(fromKey, max(fromAsset, fromAZAA)) + 1
    }

    private func dimensions(of url: URL) -> (Int, Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return (0, 0) }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?)
            as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return (width, height)
    }

    private func encode(item: ConversionItem, local: URL, profile: ConversionProfile) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(local as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw NSError(domain: "cmi.convert", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "ImageIO 打不开原图"])
        }

        var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?)
            as? [CFString: Any] ?? [:]
        let longEdge = max(item.width, item.height)
        let target = max(1, Int((Double(longEdge) * profile.clampedRatio).rounded()))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw NSError(domain: "cmi.convert", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "解码/缩放失败"])
        }

        props[kCGImagePropertyOrientation] = CGImagePropertyOrientation.up.rawValue
        props[kCGImageDestinationLossyCompressionQuality] = profile.clampedQuality

        let out = workDir.appendingPathComponent(
            "\(item.pk)-\(UUID().uuidString).\(profile.format.fileExtension.lowercased())")
        guard let destination = CGImageDestinationCreateWithURL(
            out as CFURL, profile.format.utType.identifier as CFString, 1, nil) else {
            throw NSError(domain: "cmi.convert", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "建输出失败"])
        }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "cmi.convert", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "编码失败"])
        }
        return out
    }
}
