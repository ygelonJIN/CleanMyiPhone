import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 真机探针：不启动界面，直接枚举一次并打印结果。
/// 用法：`cleanmyiphone --probe`
enum Probe {

    private static let logURL = URL(fileURLWithPath: "/tmp/cmi-probe.log")

    /// 信号源必须被保住，出了作用域就被回收，handler 也就没了
    private static var signalSources: [DispatchSourceSignal] = []

    /// 子进程收尾守卫：谁先要求退出，谁负责关 AFC / 关会话，关完立刻 `_exit`。
    /// 不这么做，主进程超时 `kill` 掉的子进程会在手机侧留半截 AFC 连接，
    /// 之后这台机器上所有 AFC 连接都会被设备直接关掉（实测三次 `--probe-afc` 全是「连接被关闭」）。
    final class HelperGuard: @unchecked Sendable {
        static let shared = HelperGuard()
        private let lock = NSLock()
        private var api: MobileDeviceAPI?
        private var device: UnsafeMutableRawPointer?
        private var afc: UnsafeMutableRawPointer?
        private var finished = false

        func attach(api: MobileDeviceAPI, device: UnsafeMutableRawPointer, afc: UnsafeMutableRawPointer) {
            lock.lock(); defer { lock.unlock() }
            self.api = api
            self.device = device
            self.afc = afc
        }

        /// 谁先触发谁生效；后来的直接睡死（第一个会在毫秒内 `_exit`）。
        func shutdown(_ reason: String, code: Int32) {
            lock.lock()
            if finished {
                lock.unlock()
                Thread.sleep(forTimeInterval: 5)
                _exit(code)
            }
            finished = true
            let api = self.api
            let device = self.device
            let afc = self.afc
            self.afc = nil
            lock.unlock()

            print("TEARDOWN \(reason)")
            fflush(stdout)
            if let api, let afc { api.closeAFC(afc) }
            if let api, let device { api.stopSession(device) }
            print("TEARDOWN \(reason) closed")
            fflush(stdout)
            _exit(code)
        }
    }

    /// 子进程的两条兜底退出通路：
    /// 1) SIGTERM / SIGINT —— 父进程超时 `terminate()` 或人按 Ctrl+C；
    /// 2) 父进程死亡 —— 父进程把一根管道的写端挂成子进程的 stdin（自己永不写），
    ///    父进程一死，子进程 `read(0,…)` 立刻 EOF。
    /// `getppid() == 1` 那套只在 `report()` 里检查，卡在第一个 AFC 调用上就永远轮不到，
    /// 而且被 `kill -9` 的父进程也不会让子进程走到任何回调。
    private static func installHelperWatchdogs() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler {
                HelperGuard.shared.shutdown("signal \(sig)", code: 4)
            }
            source.resume()
            signalSources.append(source)
        }
        guard ProcessInfo.processInfo.environment["CMI_HELPER_GUARD"] == "1" else { return }
        Thread.detachNewThread {
            var byte: UInt8 = 0
            while true {
                let got = read(0, &byte, 1)
                if got <= 0 {
                    HelperGuard.shared.shutdown("parent gone", code: 3)
                }
            }
        }
    }

    /// 子进程入口：把 /PhotoData/Photos.sqlite 拉到指定路径。
    /// 单独成进程，是因为这根 AFC 读大文件的调用会随机把堆写坏，
    /// 放在主 App 进程里会把界面一起带崩。
    private static func fetchLibrary(to path: String) {
        var code: Int32 = 1
        // 正常结束也走同一套收尾：先关 AFC、再关会话，最后才退。
        defer { HelperGuard.shared.shutdown("done", code: code) }
        installHelperWatchdogs()
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice()
            try api.openSession(device)
            let afc = try api.openAFC(device)
            HelperGuard.shared.attach(api: api, device: device, afc: afc)

            let destination = URL(fileURLWithPath: path)
            let dir = destination.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("thumbnailConfiguration"))

            // 四件套整批搬走（主库 + WAL + SHM + 缩略图配置）。
            // WAL 模式下的库必须连 -wal / -shm 一起拷，本地用普通读写模式打开，
            // 由 SQLite 自己用 salt/checksum 判断这份 WAL 配不配主文件。

            // 先量四个文件的大小，累加当进度分母（把四个文件大小累加当分母）。
            // 只用来显示进度，不用来判断「读完了没有」——seek/tell 和顺序读不是一回事。
            let paths: [(String, URL)] = [
                ("/PhotoData/Photos.sqlite", destination),
                ("/PhotoData/Photos.sqlite-wal", URL(fileURLWithPath: path + "-wal")),
                ("/PhotoData/Photos.sqlite-shm", URL(fileURLWithPath: path + "-shm")),
                ("/PhotoData/Thumbnails/thumbnailConfiguration",
                 dir.appendingPathComponent("thumbnailConfiguration"))
            ]
            var planned: Int64 = 0
            for (remote, _) in paths {
                planned += api.entrySize(afc, path: remote)
            }
            // 四个文件一个大小都量不到 = AFC 通而不通（设备侧 afcd 卡住）。
            // 别硬着头皮往下读：不给 SIZE，父进程 15 秒内就会判定失败并给出准确文案，
            // 界面也不会显示「0 KB / 1 字节」这种假分母。
            guard planned > 0 else {
                print("ERR 读不到照片库大小，AFC 无响应")
                fflush(stdout)
                code = 5
                return
            }
            print("SIZE 0 \(planned)")
            fflush(stdout)

            var done: Int64 = 0
            func report(_ bytes: Int64) {
                // 父进程被 kill / 崩溃后，这个子进程会变成孤儿继续占着 AFC，
                // 下一个实例就抢不到设备、读库卡到超时（实测"读了 3 分钟"）。
                // getppid() == 1 表示已被 launchd 收养 → 走收尾通路退出。
                if getppid() == 1 { HelperGuard.shared.shutdown("orphan", code: 3) }
                done = max(done, bytes)
                print("PROGRESS \(done) \(planned)")
                fflush(stdout)
            }

            var copied: [Int64] = []
            for (index, item) in paths.enumerated() {
                let base = done
                let name = (item.0 as NSString).lastPathComponent
                // 让界面知道现在在读哪个文件：卡住时能看到"卡在 Photos.sqlite-wal"
                print("FILE \(index + 1)/\(paths.count) \(name)")
                fflush(stdout)
                let bytes = (try? api.downloadFile(afc, path: item.0, to: item.1,
                                                   expected: api.entrySize(afc, path: item.0)) { received in
                    report(base + received)
                }) ?? 0
                done = base + bytes
                copied.append(bytes)
                report(done)
            }

            var assets = check(path: path)
            print("COPY BYTES \(copied.first ?? 0) WAL \(copied.count > 1 ? copied[1] : 0) SHM \(copied.count > 2 ? copied[2] : 0) THUMBCFG \(copied.count > 3 ? copied[3] : 0) CHECK \(assets)")
            fflush(stdout)

            // 主库不动，只重抓 wal/shm —— 一次重试只要几百毫秒，不用重下 292MB
            for attempt in 1...3 where assets == 0 {
                usleep(800_000)
                try? FileManager.default.removeItem(atPath: path + "-wal")
                try? FileManager.default.removeItem(atPath: path + "-shm")
                _ = try? api.downloadFile(afc, path: "/PhotoData/Photos.sqlite-wal",
                                          to: URL(fileURLWithPath: path + "-wal"))
                _ = try? api.downloadFile(afc, path: "/PhotoData/Photos.sqlite-shm",
                                          to: URL(fileURLWithPath: path + "-shm"))
                assets = check(path: path)
                print("RETRY \(attempt) CHECK \(assets)")
                fflush(stdout)
            }
            print("CHECK \(assets)")
            fflush(stdout)
            code = assets > 0 ? 0 : 1
        } catch {
            print("ERR \(error.localizedDescription)")
            fflush(stdout)
        }
    }

    private static func check(path: String) -> Int {
        guard let db = SQLiteDB(path: path) else { return 0 }
        // 先过完整性检查：能读到行数不代表库是完整的
        guard db.quickCheck() else { return 0 }
        return db.rows("SELECT count(*) AS c FROM ZASSET").first?.int("c") ?? 0
    }

    private static func say(_ line: String) {
        print(line)
        let text = line + "\n"
        if let data = text.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    /// 自检：验证「崩溃那一刻」用的那条删除通路（登记 → unlink）真的有效。
    /// 崩溃信号里只能调异步信号安全的东西，所以这条路必须单独验一次。
    private static func traceSelfTest() {
        let dir = TraceRegistry.dataDirectory.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("selftest-a.jpg")
        let b = dir.appendingPathComponent("selftest-b.jpg")
        let fixed = TraceRegistry.dataDirectory.appendingPathComponent("thumb-log.txt")
        try? Data("a".utf8).write(to: a)
        try? Data("b".utf8).write(to: b)
        try? Data("c".utf8).write(to: fixed)
        TraceRegistry.registerTrace(a)
        TraceRegistry.registerTrace(b)
        TraceRegistry.prepareSignalSafePaths()
        say("登记后：a=\(FileManager.default.fileExists(atPath: a.path)) b=\(FileManager.default.fileExists(atPath: b.path)) 固定名=\(FileManager.default.fileExists(atPath: fixed.path))")
        TraceRegistry.unlinkRegistered()
        let gone = !FileManager.default.fileExists(atPath: a.path)
            && !FileManager.default.fileExists(atPath: b.path)
            && !FileManager.default.fileExists(atPath: fixed.path)
        say("unlink 后：a=\(FileManager.default.fileExists(atPath: a.path)) b=\(FileManager.default.fileExists(atPath: b.path)) 固定名=\(FileManager.default.fileExists(atPath: fixed.path))")
        say(gone ? "通过" : "失败")
        exit(0)
    }

    static func runIfRequested() {
        if CommandLine.arguments.contains("--trace-selftest") {
            traceSelfTest()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--fetch-library"),
           index + 1 < CommandLine.arguments.count {
            fetchLibrary(to: CommandLine.arguments[index + 1])
            return
        }
        if CommandLine.arguments.contains("--probe-pd") {
            probePhotoData()
            return
        }
        if CommandLine.arguments.contains("--probe-icon") {
            probeIcon()
            return
        }
        if CommandLine.arguments.contains("--probe-info") {
            probeInfo()
            return
        }
        if CommandLine.arguments.contains("--probe-shot") {
            probeScreenshot()
            return
        }
        if CommandLine.arguments.contains("--probe-video") {
            probeVideo()
            return
        }
        if CommandLine.arguments.contains("--probe-apps") {
            probeApps()
            return
        }
        if CommandLine.arguments.contains("--probe-live") {
            probeLive()
            return
        }
        if CommandLine.arguments.contains("--probe-parse") {
            let started = Date()
            if let index = PhotoLibraryIndex.load(dbPath: "/tmp/cmi/Photos.sqlite") {
                say("解析：\(index.metaByFile.count) 条资产，\(index.albums.count) 个相簿，\(Int(Date().timeIntervalSince(started) * 1000)) ms")
                let hidden = index.metaByFile.values.filter(\.isHidden).count
                let fav = index.metaByFile.values.filter(\.isFavorite).count
                let trash = index.metaByFile.values.filter(\.isTrashed).count
                say("隐藏 \(hidden) · 收藏 \(fav) · 最近删除 \(trash)")
                for album in index.albumsSorted().prefix(8) {
                    say("相簿：\(album.title)（\(album.count)）")
                }
            } else {
                say("解析失败")
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--probe-db-only") {
            probeDBOnly()
            return
        }
        if CommandLine.arguments.contains("--probe-thumbs") {
            probeThumbCache()
            return
        }
        if CommandLine.arguments.contains("--probe-videos") {
            probeVideoThumbs()
            return
        }
        if CommandLine.arguments.contains("--probe-md") {
            probeMobileDevice()
            return
        }
        if CommandLine.arguments.contains("--probe-afc") {
            probeAFC()
            return
        }
        if CommandLine.arguments.contains("--probe-keys") {
            probeKeys()
            return
        }
        if CommandLine.arguments.contains("--probe-battery") {
            probeBattery()
            return
        }
        if CommandLine.arguments.contains("--probe-dcim") {
            probeDCIM()
            return
        }
        if CommandLine.arguments.contains("--probe-thumbdir") {
            probeThumbDir()
            return
        }
        if CommandLine.arguments.contains("--probe-thumb") {
            probeThumb()
            return
        }
        if CommandLine.arguments.contains("--probe-appsize") {
            probeAppSize()
            return
        }
        if CommandLine.arguments.contains("--probe-house") {
            probeHouse()
            return
        }
        if CommandLine.arguments.contains("--probe-airlock") {
            probeAirlock()
            return
        }
        if CommandLine.arguments.contains("--probe-upload") {
            probeUpload()
            return
        }
        if CommandLine.arguments.contains("--probe-livefiles") {
            probeLiveFiles()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--probe-livefetch"),
           index + 1 < CommandLine.arguments.count {
            probeLiveFetch(libraryPath: CommandLine.arguments[index + 1])
            return
        }
        if CommandLine.arguments.contains("--probe-verify2046") {
            probeVerify2046()
            return
        }
        if CommandLine.arguments.contains("--probe-verify") {
            probeVerify()
            return
        }
        if CommandLine.arguments.contains("--probe-db-write") {
            probeDbWrite()
            return
        }
        if CommandLine.arguments.contains("--probe-edit") {
            probeEdit()
            return
        }
        if CommandLine.arguments.contains("--probe-edit-check") {
            probeEditCheck()
            return
        }
        if CommandLine.arguments.contains("--probe-reboot") {
            probeReboot()
            return
        }
        if CommandLine.arguments.contains("--probe-write") {
            probeWrite()
            return
        }
        if CommandLine.arguments.contains("--probe-check") {
            probeCheck()
            return
        }
        if CommandLine.arguments.contains("--probe-daemon") {
            probeDaemon()
            return
        }
        if CommandLine.arguments.contains("--convert-batch") {
            convertBatch()
            return
        }
        if CommandLine.arguments.contains("--probe-convert2046") {
            probeConvert2046()
            return
        }
        if CommandLine.arguments.contains("--probe-convert") {
            probeConvert()
            return
        }
        guard CommandLine.arguments.contains("--probe") else { return }

        let bridge = PTPBridge()
        var assets: [Asset] = []

        bridge.onDevice = { device in
            print("设备：\(device?.name ?? "无") / \(device?.model ?? "-")")
        }
        bridge.onCatalog = { list, progress in
            assets = list
            print("目录：\(list.count) 项，进度 \(Int(progress * 100))%")
        }
        bridge.onError = { message in
            print("错误：\(message)")
        }

        bridge.start()

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline && assets.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        if assets.isEmpty {
            print("结果：25 秒内没有读到任何媒体")
        } else {
            let bytes = assets.reduce(Int64(0)) { $0 + $1.byteSize }
            print("结果：共 \(assets.count) 项，合计 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
            let byKind = Dictionary(grouping: assets, by: \.kind)
            for (kind, list) in byKind.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                print("  \(kind.label)：\(list.count) 项")
            }
            let tagged = assets.filter { !$0.tags.isEmpty }
            print("  带标签：\(tagged.count) 项（连拍/慢动作/延时/实况）")
            print("  媒体页前 5 项：")
            for asset in assets.sorted(by: { $0.createdAt > $1.createdAt }).prefix(5) {
                print("   - \(asset.fileName)  \(asset.sizeText)  \(asset.folder)  \(asset.dateText)")
            }
        }

        // 缩略图通路验证（不下载原图）
        if let first = assets.first {
            let started = Date()
            var got: NSImage?
            let sem = DispatchSemaphore(value: 0)
            Task {
                got = await bridge.thumbnail(for: first, maxPixel: 512)
                sem.signal()
            }
            // 等待异步缩略图，同时保持 runloop 转动
            while sem.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                if Date().timeIntervalSince(started) > 15 { break }
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if let got {
                print("缩略图：\(Int(got.size.width))×\(Int(got.size.height))，耗时 \(ms) ms")
            } else {
                print("缩略图：取不到（\(ms) ms）")
            }
        }

        bridge.stop()
        exit(0)
    }


    /// 视频缩略图为什么取不到：逐条比对「库里的 ZDIRECTORY/ZFILENAME」→
    /// V2 缓存目录存在吗、末级文件叫什么、原片在不在、iCloud 是否已落地。
    private static func probeVideoThumbs() {
        let dbPath = PurgeGuard.dataDirectory + "/Photos.sqlite"
        guard let index = PhotoLibraryIndex.load(dbPath: dbPath), !index.isEmpty else {
            say("没有本地快照，先跑一次读库")
            exit(1)
        }
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 15)
            try api.openSession(device)
            let afc = try api.openAFC(device)

            // 全量审计：每一条资产都试一遍 V2 缓存 + 原片大小
            let all = Array(index.metaByFile.values)
            var hit = 0
            var stubs: [(PhotoLibraryIndex.Meta, Int64)] = []      // 原片 0 字节（iCloud 离线）
            var noThumb: [(PhotoLibraryIndex.Meta, Int64)] = []     // 没缓存但有原片
            var tiny: [PhotoLibraryIndex.Meta] = []
            for meta in all {
                let dir = meta.directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let itemPath = "/PhotoData/Thumbnails/V2/\(dir)/\(meta.fileName)"
                var got = false
                for leaf in ["5005.JPG", "5003.JPG", "5007.JPG"] {
                    if let data = try? api.readFile(afc, path: "\(itemPath)/\(leaf)", limit: 4 << 20),
                       !data.isEmpty { got = true; break }
                }
                if !got {
                    for leaf in ((try? api.listDirectory(afc, path: itemPath)) ?? []) where leaf.uppercased().hasSuffix(".JPG") {
                        if let data = try? api.readFile(afc, path: "\(itemPath)/\(leaf)", limit: 4 << 20),
                           !data.isEmpty { got = true; break }
                    }
                }
                if got { hit += 1; continue }
                var ref: UnsafeMutableRawPointer?
                let status = api.openFileStatus(afc, path: "/\(dir)/\(meta.fileName)", &ref)
                if let ref { api.closeFile(afc, ref) }
                let diskSize = status == 0 ? api.entrySize(afc, path: "/\(dir)/\(meta.fileName)") : 0
                if status != 0 { noThumb.append((meta, -1)) }
                else if diskSize == 0 { stubs.append((meta, 0)) }
                else { noThumb.append((meta, diskSize)) }
                if meta.byteSize < 100_000 { tiny.append(meta) }
            }
            say("全量 \(all.count) 条：V2 命中 \(hit)，"
                + "原片 0 字节 \(stubs.count)，有原片但没缩略图 \(noThumb.count)")
            for (meta, disk) in stubs.prefix(8) {
                say("  0字节 \(meta.fileName)  \(meta.directory)  库记 \(meta.byteSize) B  \(meta.isVideo ? "视频" : "照片")")
            }
            for (meta, disk) in noThumb.prefix(8) {
                say("  无缓存 \(meta.fileName)  \(meta.directory)  库记 \(meta.byteSize) B  盘上 \(disk) B  \(meta.isVideo ? "视频" : "照片")")
            }
            say("其中不满 100 KB 的失败 \(tiny.count) 条：\(tiny.prefix(8).map(\.fileName).joined(separator: ","))")

            // 第 4 层匹配（±2 秒 + 同种类）覆盖率自检：视频最容易需要它
            var videoTotal = 0, videoResolved = 0, zeroHits = 0
            let bySec = Dictionary(grouping: all) { Int($0.createdAt.timeIntervalSinceReferenceDate.rounded()) }
            for meta in all where meta.isVideo {
                videoTotal += 1
                let base = Int(meta.createdAt.timeIntervalSinceReferenceDate.rounded())
                let window = (-2...2).flatMap { bySec[base + $0] ?? [] }.filter(\.isVideo)
                if window.isEmpty { zeroHits += 1 }
                if index.meta(matchingTimeOf: meta.createdAt, isVideo: true) != nil { videoResolved += 1 }
            }
            let coverage = index.timeIndexCoverage
            _ = coverage
            _ = zeroHits
            let ambiguous: [String] = []
            let exampleNote = ambiguous.isEmpty ? "" : "  例：" + ambiguous.joined(separator: ",")
            say("按拍摄时间±2秒匹配：视频 \(videoTotal) 条里能唯一定位 \(videoResolved)，有歧义 \(videoTotal - videoResolved)\(exampleNote)")
            api.stopSession(device)
        } catch {
            say("失败：\(error.localizedDescription)")
        }
        exit(0)
    }

    private static func entrySizeOf(_ api: MobileDeviceAPI, _ afc: UnsafeMutableRawPointer, _ relative: String) -> Int64 {
        for candidate in ["/\(relative)", "/DCIM/\(relative)"] {
            let size = api.entrySize(afc, path: candidate)
            if size > 0 { return size }
        }
        return 0
    }

    /// 设备端缩略图缓存探针：iMazing 直接读 `/PhotoData/Thumbnails/V2`
    /// （见 imazing-reverse/FILESYSTEM.md）。这里确认目录结构、数量、单张大小，
    /// 判断能不能用「批量 AFC 读几千张小图」替代「逐张问 PTP / 下整份原图」。
    private static func probeThumbCache() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 15)
            try api.openSession(device)
            let afc = try api.openAFC(device)
            for dir in ["/PhotoData/Thumbnails", "/PhotoData/Thumbnails/V2"] {
                let list = (try? api.listDirectory(afc, path: dir)) ?? []
                say("\(dir)：\(list.count) 项  \(list.prefix(20).joined(separator: ", "))")
                var files = 0
                var total: Int64 = 0
                var sample: String?
                for entry in list.prefix(40) {
                    let path = "\(dir)/\(entry)"
                    let size = api.entrySize(afc, path: path)
                    if size > 0 {
                        files += 1
                        total += size
                        if sample == nil, size > 512, size < 400_000 { sample = path }
                    }
                }
                say("  前 40 项里：文件 \(files) 个，合计 \(total) B，示例 \(sample ?? "-")")
            }
            // 下几张小图看看：大小 + 文件头（JPEG / HEIC / PLIST？）
            for dir in ["/PhotoData/Thumbnails/V2/DCIM", "/PhotoData/Thumbnails/V2/PhotoData"] {
                guard let sub = (try? api.listDirectory(afc, path: dir))?.first else { continue }
                let subPath = "\(dir)/\(sub)"
                let inner = (try? api.listDirectory(afc, path: subPath)) ?? []
                say("\(subPath)：\(inner.count) 项  \(inner.prefix(10).joined(separator: ", "))")
                for name in inner.prefix(4) {
                    let path = "\(subPath)/\(name)"
                    let size = api.entrySize(afc, path: path)
                    let data = try? api.readFile(afc, path: path, limit: 64)
                    let head = data?.prefix(12).map { String(format: "%02x", $0) }.joined() ?? "-"
                    say("  \(name)  \(size) B  head=\(head)")
                    // 里面还有一层：Apple 的 V2 缓存是 `<原文件名>/<缩略图名>.jpeg`
                    let deeper = (try? api.listDirectory(afc, path: path)) ?? []
                    if !deeper.isEmpty {
                        say("    └ \(deeper.count) 项：\(deeper.prefix(6).joined(separator: ", "))")
                        for leaf in deeper.prefix(3) {
                            let leafPath = "\(path)/\(leaf)"
                            let leafSize = api.entrySize(afc, path: leafPath)
                            let leafData = try? api.readFile(afc, path: leafPath, limit: 16)
                            let leafHead = leafData?.prefix(8).map { String(format: "%02x", $0) }.joined() ?? "-"
                            say("      \(leaf)  \(leafSize) B  head=\(leafHead)")
                        }
                    }
                }
            }
            // 视频也走同一套缓存吗？直接验一条 .MP4
            let sampleDir = "/PhotoData/Thumbnails/V2/DCIM"
            if let folder = (try? api.listDirectory(afc, path: sampleDir))?.first {
                let folderPath = "\(sampleDir)/\(folder)"
                let names = (try? api.listDirectory(afc, path: folderPath)) ?? []
                for name in names where name.uppercased().hasSuffix(".MP4") || name.uppercased().hasSuffix(".MOV") {
                    let itemPath = "\(folderPath)/\(name)"
                    let leaves = (try? api.listDirectory(afc, path: itemPath)) ?? []
                    say("视频缓存 \(name)：\(leaves.count) 项 \(leaves.prefix(5).joined(separator: ", "))")
                    for leaf in leaves.prefix(3) {
                        let leafPath = "\(itemPath)/\(leaf)"
                        let leafSize = api.entrySize(afc, path: leafPath)
                        let started = Date()
                        let data = try? api.readFile(afc, path: leafPath, limit: 2_000_000)
                        say("  \(leaf)  \(leafSize) B  读到 \(data?.count ?? 0) B，"
                            + String(format: "%.0f ms", Date().timeIntervalSince(started) * 1000))
                    }
                }
                // 直接按「原文件名/5005.JPG」这条路试一次，读整张
                if let first = names.first(where: { !$0.hasSuffix("APPLE") }) {
                    let direct = "\(folderPath)/\(first)/5005.JPG"
                    let size = api.entrySize(afc, path: direct)
                    let started = Date()
                    let data = try? api.readFile(afc, path: direct, limit: 2_000_000)
                    say("直读 \(direct)：\(size) B / 读到 \(data?.count ?? 0) B，"
                        + String(format: "%.0f ms", Date().timeIntervalSince(started) * 1000))
                }
            }
            // 用**真实库索引**里的 ZDIRECTORY/ZFILENAME 拼路径，验证生产代码那条拼法对不对
            let dbPath = PurgeGuard.dataDirectory + "/Photos.sqlite"
            if let index = PhotoLibraryIndex.load(dbPath: dbPath), !index.isEmpty {
                let metas = Array(index.metaByFile.values.prefix(300))
                var hit = 0
                var miss = 0
                var bytes = 0
                var ms: Double = 0
                var samples: [String] = []
                for meta in metas {
                    let dir = meta.directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let path = "/PhotoData/Thumbnails/V2/\(dir)/\(meta.fileName)/5005.JPG"
                    let started = Date()
                    if let data = try? api.readFile(afc, path: path, limit: 4 << 20), !data.isEmpty {
                        hit += 1
                        bytes += data.count
                        ms += Date().timeIntervalSince(started) * 1000
                    } else {
                        miss += 1
                        if samples.count < 3 { samples.append(path) }
                    }
                }
                say("按库索引拼路径：命中 \(hit) / 未命中 \(miss)，平均 "
                    + String(format: "%.1f ms", hit > 0 ? ms / Double(hit) : 0)
                    + "，平均 \(hit > 0 ? bytes / hit : 0) B")
                for sample in samples { say("  未命中示例：\(sample)") }
            }
            api.stopSession(device)
        } catch {
            say("失败：\(error.localizedDescription)")
        }
        exit(0)
    }

    /// 照片库目录探针：看 AlbumsMetadata / CPL 里有什么
    private static func probePhotoData() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 15)
            try api.openSession(device)
            let afc = try api.openAFC(device)
            for dir in ["/PhotoData/AlbumsMetadata", "/PhotoData/CPL", "/PhotoData/Caches",
                        "/PhotoData/.Photos_SUPPORT"] {
                let list = (try? api.listDirectory(afc, path: dir)) ?? []
                say("\(dir)：\(list.count) 项  \(list.prefix(10).joined(separator: ", "))")
            }
        } catch {
            say("失败：\(error.localizedDescription)")
        }
        exit(0)
    }

    /// 应用图标探针
    private static func probeIcon() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 15)
            try api.openSession(device)
            for bundle in ["com.apple.Preferences", "com.tencent.xin"] {
                let started = Date()
                if let data = try api.appIcon(device, bundleID: bundle) {
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    try? data.write(to: URL(fileURLWithPath: "/tmp/icon-\(bundle).png"))
                    say("\(bundle)：\(data.count) 字节，\(ms) ms")
                } else {
                    say("\(bundle)：没有图标")
                }
            }
        } catch {
            say("失败：\(error.localizedDescription)")
        }
        exit(0)
    }

    /// 把 lockdownd 里能读到的都打出来，用来找容量/电话/运营商的真实键
    private static func probeInfo() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 15)
            try api.openSession(device)

            let base = api.allValues(device)
            say("基础域键数：\(base.count)")
            for key in base.keys.sorted() where key.lowercased().contains("phone")
                || key.lowercased().contains("carrier")
                || key.lowercased().contains("sim")
                || key.lowercased().contains("serial")
                || key.lowercased().contains("model")
                || key.lowercased().contains("name") {
                say("  \(key) = \(base[key] ?? "-")")
            }

            let disk = api.allValues(device, domain: "com.apple.disk_usage")
            say("disk_usage 键：\(disk.keys.sorted().joined(separator: ", "))")
            for (key, value) in disk.sorted(by: { $0.key < $1.key }) {
                say("  \(key) = \(value)")
            }

            let battery = api.allValues(device, domain: "com.apple.mobile.battery")
            say("battery: \(battery.keys.sorted().joined(separator: ", "))")
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// 截图探针
    private static func probeScreenshot() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 15)
            try api.openSession(device)
            let started = Date()
            if let data = try api.screenshot(device) {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                try data.write(to: URL(fileURLWithPath: "/tmp/cmi-shot.png"))
                say("截图成功：\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))，\(ms) ms")
            } else {
                say("截图失败：没有图片数据")
            }
        } catch {
            say("截图失败：\(error.localizedDescription)")
        }
        exit(0)
    }

    /// 视频取回探针：挑一个最小的视频，用 AFC 拉回来
    private static func probeVideo() {
        let bridge = PTPBridge()
        var assets: [Asset] = []
        bridge.onCatalog = { list, _ in assets = list }
        bridge.start()
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline && assets.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        bridge.stop()

        guard let video = assets.filter({ $0.kind == .video }).min(by: { $0.byteSize < $1.byteSize }) else {
            say("没有找到视频")
            exit(1)
        }
        say("测试视频：\(video.fileName) \(video.sizeText)")

        final class Box: @unchecked Sendable { var url: URL?; var done = false; var error: String? }
        let box = Box()
        Task { @MainActor in
            box.url = await DeviceFiles.shared.download(fileName: video.fileName,
                                                        to: FileManager.default.temporaryDirectory.appendingPathComponent("cmi-video"))
            box.error = DeviceFiles.shared.lastError
            box.done = true
        }
        let limit = Date().addingTimeInterval(120)
        while !box.done && Date() < limit {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if let url = box.url {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            say("已取回：\(url.lastPathComponent)，\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        } else {
            say("取回失败：\(box.error ?? "未知")")
            exit(1)
        }
        exit(0)
    }

    /// 应用占用探针
    private static func probeApps() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 15)
            try api.openSession(device)
            let service = try api.openService(device, name: "com.apple.mobile.installation_proxy")
            _ = api.serviceRequest(service, [
                "Command": "Browse",
                "ClientOptions": ["Attributes": ["StaticDiskUsage", "DynamicDiskUsage", "BundleSize", "CFBundleDisplayName"]]
            ])
            var entries: [[String: Any]] = []
            for _ in 0..<60 {
                let chunk = api.serviceRequest(service, ["Command": "Browse"])
                if let list = chunk["CurrentList"] as? [[String: Any]] {
                    entries.append(contentsOf: list)
                }
                if let status = chunk["Status"] as? String, status == "Complete" { break }
                if chunk.isEmpty { break }
            }
            let result = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (String, Any)? in
                guard let id = entry["CFBundleIdentifier"] as? String else { return nil }
                return (id, entry)
            })
            say("应用条目：\(result.count)")
            var shown = 0
            for (key, value) in result {
                guard let info = value as? [String: Any] else { continue }
                if shown < 3 {
                    let keys = info.keys.sorted().joined(separator: ",")
                    let staticValue = info["StaticDiskUsage"].map { "\($0)" } ?? "nil"
                    let dynamicValue = info["DynamicDiskUsage"].map { "\($0)" } ?? "nil"
                    say("\(key) static=\(staticValue) dynamic=\(dynamicValue)")
                    say("  keys: \(keys)")
                    shown += 1
                }
            }
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// 端到端：PTP 枚举 + 相簿库合并
    private static func probeLive() {
        let bridge = PTPBridge()
        var assets: [Asset] = []
        bridge.onCatalog = { list, _ in assets = list }
        bridge.start()
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline && assets.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        say("PTP：\(assets.count) 项")
        bridge.stop()

        final class Box: @unchecked Sendable {
            var index: PhotoLibraryIndex?
            var stats: LibraryService.DeviceStats?
            var done = false
            var error: String?
        }
        let box = Box()
        Task { @MainActor in
            do {
                let snapshot = try await LibraryService.fetch { _ in }
                box.index = snapshot.index
                box.stats = snapshot.stats
            } catch {
                box.error = error.localizedDescription
            }
            box.done = true
        }
        let limit = Date().addingTimeInterval(90)
        while !box.done && Date() < limit {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let index = box.index

        guard let index else {
            say("相簿库：失败（\(box.error ?? "超时")）")
            exit(1)
        }
        let names = Set(index.metaByFile.keys)
        let matched = assets.filter {
            index.meta(for: $0.fileName) != nil
                || index.meta(matching: $0.byteSize, date: $0.createdAt) != nil
        }.count
        let hidden = index.metaByFile.values.filter(\.isHidden).count
        let fav = index.metaByFile.values.filter(\.isFavorite).count
        let trash = index.metaByFile.values.filter(\.isTrashed).count
        say("相簿库：\(index.metaByFile.count) 条资产 / \(index.albums.count) 个相簿")
        say("合并：PTP \(assets.count) 项中 \(matched) 项在库里有记录")
        say("隐藏 \(hidden) · 收藏 \(fav) · 最近删除 \(trash)")
        if let stats = box.stats {
            say("容量：总 \(ByteCountFormatter.string(fromByteCount: stats.totalCapacity, countStyle: .file)) · 可用 \(ByteCountFormatter.string(fromByteCount: stats.available, countStyle: .file))")
            say("应用：\(stats.appCount) 个，合计 \(ByteCountFormatter.string(fromByteCount: stats.appBytes, countStyle: .file))")
            say("型号 \(stats.productType) · 系统 \(stats.productVersion) · 序列号 \(stats.serial)")
            say("电话 \(stats.phoneNumber.isEmpty ? "—" : stats.phoneNumber) · 运营商 \(stats.carrier.isEmpty ? "—" : stats.carrier) · 电池 \(stats.batteryLevel)%")
        }
        if let stats = box.stats {
            say("容量：总 \(ByteCountFormatter.string(fromByteCount: stats.totalCapacity, countStyle: .file)) · 可用 \(ByteCountFormatter.string(fromByteCount: stats.available, countStyle: .file))")
            say("应用：\(stats.appCount) 个，合计 \(ByteCountFormatter.string(fromByteCount: stats.appBytes, countStyle: .file))")
            say("型号 \(stats.productType) · 系统 \(stats.productVersion) · 序列号 \(stats.serial)")
            say("电话 \(stats.phoneNumber.isEmpty ? "—" : stats.phoneNumber) · 运营商 \(stats.carrier.isEmpty ? "—" : stats.carrier) · 电池 \(stats.batteryLevel)%")
        }
        let unmatched = assets.filter { index.meta(for: $0.fileName) == nil }.prefix(6)
        for asset in unmatched { say("未匹配：\(asset.fileName)  \(asset.folder)  \(asset.kind.label)") }
        let ptpNames = Set(assets.map { PhotoLibraryIndex.normalize($0.fileName) })
        let dbOnly = names.filter { !ptpNames.contains($0) }.prefix(4)
        for name in dbOnly { say("仅库内：\(name)") }
        if let top = index.albumsSorted().first {
            say("最大相簿：\(top.title)（\(top.count)）")
        }
        exit(0)
    }

    private static func probeDBOnly() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice()
            try api.openSession(device)
            let afc = try api.openAFC(device)
            _ = try? api.listDirectory(afc, path: "/")
            _ = try? api.listDirectory(afc, path: "/DCIM")
            _ = try? api.listDirectory(afc, path: "/PhotoData")
            let url = URL(fileURLWithPath: "/tmp/dbonly/Photos.sqlite")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = try api.downloadFile(afc, path: "/PhotoData/Photos.sqlite", to: url)
            say("bytes \(bytes)")
            let wal = (try? api.downloadFile(afc, path: "/PhotoData/Photos.sqlite-wal",
                                             to: URL(fileURLWithPath: "/tmp/dbonly/Photos.sqlite-wal"))) ?? 0
            say("wal \(wal)")
        } catch {
            say("err \(error.localizedDescription)")
        }
        exit(0)
    }

    /// MobileDevice.framework + AFC 探针
    private static func probeMobileDevice() {
        say("探针：开始")
        do {
            let api = try MobileDeviceAPI.shared()
            say("MobileDevice：已加载")
            let device = try api.firstDevice()
            say("设备句柄：已获取")
            try api.openSession(device)
            say("会话：已建立")
            let info = api.info(device)
            say("设备：\(info.name) / \(info.productType) / iOS \(info.productVersion)")
            say("UDID：\(info.identifier)")
            let afc = try api.openAFC(device)
            say("AFC：已连接")
            let root = try api.listDirectory(afc, path: "/")
            say("根目录：\(root.sorted().joined(separator: ", "))")
            for probe in ["/DCIM", "/PhotoData"] {
                let list = (try? api.listDirectory(afc, path: probe)) ?? []
                say("\(probe)：\(list.count) 项  \(list.sorted().prefix(8).joined(separator: ", "))")
            }

            // 关键一步：设备照片库能不能读
            let started = Date()
            let dbURL = URL(fileURLWithPath: "/tmp/cmi/Photos.sqlite")
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
            try? FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                let dbBytes = try api.downloadFile(afc, path: "/PhotoData/Photos.sqlite", to: dbURL)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                say("Photos.sqlite：\(ByteCountFormatter.string(fromByteCount: dbBytes, countStyle: .file))，\(ms) ms")
                let walBytes = (try? api.downloadFile(afc, path: "/PhotoData/Photos.sqlite-wal",
                                                     to: URL(fileURLWithPath: "/tmp/cmi/Photos.sqlite-wal"))) ?? 0
                say("Photos.sqlite-wal：\(ByteCountFormatter.string(fromByteCount: walBytes, countStyle: .file))")
                say("已保存到 /tmp/cmi/")
            } catch {
                say("Photos.sqlite：读不到（\(error.localizedDescription)）")
            }
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// usbmux + lockdownd 探针
    private static func probeAFC() {
        let client = AFClient()
        do {
            let devices = try client.listDevices()
            say("usbmux 设备数：\(devices.count)")
            for device in devices {
                say("  ID=\(device.deviceID) 序列号=\(device.serial) 连接=\(device.connectionType)")
            }
            guard let device = devices.first else {
                say("结果：没有设备")
                exit(1)
            }
            let fd = try client.connectLockdown(deviceID: device.deviceID)
            defer { close(fd) }
            say("lockdownd：已连接")
            say("QueryType：\(try client.queryType(fd: fd))")

            let info = try client.getValue(fd: fd)
            for key in ["DeviceName", "ProductType", "ProductVersion", "BuildVersion", "UniqueDeviceID"] {
                say("\(key) = \(info[key] ?? "—")")
            }
            let disk = (try? client.getValue(fd: fd, domain: "com.apple.disk_usage")) ?? [:]
            if let total = disk["TotalDataCapacity"], let free = disk["TotalDataAvailable"] {
                say("容量：总 \(total) / 可用 \(free)")
            }
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    // MARK: - 三条决定界面写多满的探针


    /// 4) 应用体积/图标到底有没有：换几组 Attributes 和命令试
    private static func probeAppSize() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice()
            try api.openSession(device)
            let service = try api.openService(device, name: "com.apple.mobile.installation_proxy")

            let attributeSets: [[String]] = [
                ["BundleSize", "StaticDiskUsage", "DynamicDiskUsage", "FileSize"],
                ["CFBundleDisplayName", "ApplicationType", "ApplicationDSID", "InstallationDate", "Path", "Container"],
                ["BundleSize", "StaticDiskUsage", "DynamicDiskUsage", "CFBundleDisplayName",
                 "ApplicationType", "CFBundleIcons", "CFBundleIconFiles", "Path"]
            ]
            for attributes in attributeSets {
                let response = api.serviceRequest(service, ["Command": "Lookup",
                                                            "ClientOptions": ["Attributes": attributes]])
                let result = (response["LookupResult"] as? [String: Any]) ?? response
                say("Attributes \(attributes)：条目 \(result.count)")
                if let wechat = result["com.tencent.xin"] as? [String: Any] {
                    for key in ["BundleSize", "StaticDiskUsage", "DynamicDiskUsage", "FileSize", "Path",
                                "Container", "ApplicationType", "CFBundleIcons", "CFBundleIconFiles"] {
                        say("  com.tencent.xin[\(key)] = \(wechat[key].map { "\($0)" } ?? "nil")")
                    }
                }
                // 统计 ApplicationType 的分布，顺便看哪些被算成「系统」
                var types: [String: Int] = [:]
                var samples: [String] = []
                for (key, value) in result {
                    guard let info = value as? [String: Any] else { continue }
                    let type = (info["ApplicationType"] as? String) ?? "nil"
                    types[type, default: 0] += 1
                    if key.hasPrefix("com.apple.") || key.lowercased().contains("carplay") {
                        if samples.count < 6 { samples.append("\(key)=\(type)") }
                    }
                }
                say("  ApplicationType 分布：\(types)")
                say("  com.apple.* / carplay 样例：\(samples.joined(separator: ", "))")
            }
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// 5) 缩略图通路：网格靠这条，预览已经能靠 AFC 兜底，所以要看单独会不会回
    private static func probeThumb() {
        let bridge = PTPBridge()
        var list: [Asset] = []
        let gate = DispatchSemaphore(value: 0)
        bridge.onCatalog = { assets, _ in
            if assets.count > list.count { list = assets }
            if assets.count > 5, gate.wait(timeout: .now()) == .success { } else if assets.count > 5 { gate.signal() }
        }
        bridge.start()
        _ = gate.wait(timeout: .now() + 25)
        say("枚举到 \(list.count) 项")
        guard !list.isEmpty else { exit(1) }

        var done = false
        Task {
            for asset in list.prefix(3) {
                let builtin = await bridge.debugThumbnail(for: asset, maxPixel: nil)
                let small = await bridge.debugThumbnail(for: asset, maxPixel: 480)
                let big = await bridge.debugThumbnail(for: asset, maxPixel: 1600)
                say("\(asset.fileName)｜内置 \(builtin.0) (\(builtin.1))｜480 字节 \(small.0) (\(small.1))｜1600 字节 \(big.0) (\(big.1))")
            }
            done = true
        }
        while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        exit(0)
    }

    /// 7) DCIM 实测体积：跟手机「照片」那一栏对一对
    private static func probeDCIM() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 10)
            try api.openSession(device)
            let afc = try api.openAFC(device)
            let started = Date()
            var total: Int64 = 0
            var files = 0
            let folders = (try? api.listDirectory(afc, path: "/DCIM")) ?? []
            for folder in folders where folder.first?.isNumber == true || folder.first?.isLetter == true {
                let path = "/DCIM/\(folder)"
                for name in (try? api.listDirectory(afc, path: path)) ?? [] {
                    let size = api.entrySize(afc, path: "\(path)/\(name)")
                    if size > 0 { total += size; files += 1 }
                }
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            say("DCIM：\(folders.count) 个目录，\(files) 个文件，\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))，耗时 \(ms) ms")

            // 顺带量一下 PhotoData（缩略图、衍生、数据库都在这）
            var photoData: Int64 = 0
            for name in (try? api.listDirectory(afc, path: "/PhotoData")) ?? [] {
                let size = api.entrySize(afc, path: "/PhotoData/\(name)")
                if size > 0 { photoData += size }
            }
            say("PhotoData 顶层文件合计：\(ByteCountFormatter.string(fromByteCount: photoData, countStyle: .file))")
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// 6) 缩略图缓存目录：V2 到底长什么样，决定了能不能绕开 PTP
    private static func probeThumbDir() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 10)
            try api.openSession(device)
            let afc = try api.openAFC(device)
            // 对照：原图能不能读，用来区分「AFC 被 PTP 堵住」和「缩略图文件本身不可读」
            for probe in ["/DCIM/100APPLE/IMG_0005.JPG", "/PhotoData/Thumbnails/V2/DCIM/100APPLE/IMG_0005.JPG"] {
                let data = (try? api.readFile(afc, path: probe, limit: 65536)) ?? Data()
                say("对照读取 \(probe) -> \(data.count) 字节")
            }

            let root = "/PhotoData/Thumbnails"
            let top = (try? api.listDirectory(afc, path: root)) ?? []
            say("\(root)：\(top.count) 项 -> \(top.sorted().prefix(12).joined(separator: ", "))")

            let v2 = root + "/V2"
            let level1 = (try? api.listDirectory(afc, path: v2)) ?? []
            say("V2：\(level1.count) 项 -> \(level1.sorted().prefix(12).joined(separator: ", "))")

            // 往下钻两层，看文件名规律
            for name in level1.sorted().prefix(3) {
                let p1 = "\(v2)/\(name)"
                let level2 = (try? api.listDirectory(afc, path: p1)) ?? []
                say("  \(name)/：\(level2.count) 项 -> \(level2.sorted().prefix(8).joined(separator: ", "))")
                for sub in level2.sorted().prefix(1) {
                    let p2 = "\(p1)/\(sub)"
                    let level3 = (try? api.listDirectory(afc, path: p2)) ?? []
                    say("    \(sub)/：\(level3.count) 项 -> \(level3.sorted().prefix(8).joined(separator: ", "))")
                    if let first = level3.sorted().first {
                        let file = "\(p2)/\(first)"
                        let size = api.entrySize(afc, path: file)
                        let data = (try? api.readFile(afc, path: file, limit: 512 * 1024)) ?? Data()
                        let image = data.isEmpty ? nil : NSImage(data: data)
                        say("    样例 \(file) = \(size) 字节，读出 \(data.count) 字节，解码 \(image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "失败")")
                    }
                }
            }
            // 再试一条最可能的直取路径
            if let index = CommandLine.arguments.firstIndex(of: "--thumb-index"),
               index + 1 < CommandLine.arguments.count,
               let n = Int(CommandLine.arguments[index + 1]) {
                for candidate in ["\(v2)/\(n % 1000).jpg", "\(v2)/\(n).jpg",
                                  "\(v2)/\(n / 1000)/\(n).jpg", "\(v2)/\(n / 1000)/\(n % 1000).jpg"] {
                    say("候选 \(candidate) -> \(api.entrySize(afc, path: candidate)) 字节")
                }
            }
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// 1) 基础域全键 dump：确认 ModelNumber / PasswordProtected / DeviceLocked 到底有没有
    private static func probeKeys() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice()
            try api.openSession(device)
            say("锁屏：\(api.isLocked(device) ? "是" : "否")")
            let base = api.allValues(device)
            say("基础域键数：\(base.count)")
            for key in base.keys.sorted() {
                let value = base[key]
                let text = (value as? String) ?? String(describing: value ?? "—")
                say("  \(key) = \(text.prefix(160))")
            }
            for domain in ["com.apple.mobile.battery", "com.apple.disk_usage", "com.apple.mobile.iTunes"] {
                let values = api.allValues(device, domain: domain)
                say("域 \(domain)：\(values.count) 个键")
                for key in values.keys.sorted() {
                    let text = (values[key] as? String) ?? String(describing: values[key] ?? "—")
                    say("  \(key) = \(text.prefix(120))")
                }
            }
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// 2) 电池 IORegistry：设计容量 / 有效最大 / 温度 / 循环次数
    private static func probeBattery() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice()
            try api.openSession(device)
            say("锁屏：\(api.isLocked(device) ? "是" : "否")")

            do {
                let service = try api.openService(device, name: "com.apple.mobile.diagnostics_relay")
                say("diagnostics_relay：已启动")
                // 把几种请求形态都试一遍，看哪种回东西
                let attempts: [[String: Any]] = [
                    ["Request": "IORegistry", "EntryName": "AppleSmartBattery", "CurrentPlane": "IOService"],
                    ["Request": "IORegistry", "EntryClass": "AppleSmartBattery", "CurrentPlane": "IOService"],
                    ["Request": "IORegistry", "CurrentPlane": "IOService"],
                    ["Request": "All"],
                    ["Request": "GasGauge"]
                ]
                for (index, payload) in attempts.enumerated() {
                    let response = api.serviceRequest(service, payload)
                    say("请求 \(index) \(payload)：\(response.count) 个顶层键 -> \(response.keys.sorted().joined(separator: ", "))")
                    if let diagnostics = response["Diagnostics"] as? [String: Any] {
                        say("  Diagnostics 键：\(diagnostics.keys.sorted().prefix(20).joined(separator: ", "))")
                        for (key, value) in diagnostics where value is [String: Any] {
                            let inner = (value as? [String: Any]) ?? [:]
                            say("  ↳ \(key)（\(inner.count) 个键）：\(inner.keys.sorted().prefix(25).joined(separator: ", "))")
                            // IORegistry 是棵树：把 regEntry 里的属性键也打出来
                            if let reg = inner["regEntry"] as? [String: Any] {
                                say("    regEntry（\(reg.count) 个键）：\(reg.keys.sorted().prefix(40).joined(separator: ", "))")
                                for (prop, propValue) in reg where prop.lowercased().contains("capacit")
                                    || prop.lowercased().contains("temperature") || prop.lowercased().contains("cycle") {
                                    say("      \(prop) = \(propValue)")
                                }
                            }
                            if let children = inner["children"] as? [[String: Any]] {
                                say("    children：\(children.count) 个节点 -> \(children.compactMap { $0["name"] as? String }.prefix(12).joined(separator: ", "))")
                            }
                        }
                        if let gauge = diagnostics["GasGauge"] as? [String: Any] {
                            say("  GasGauge 明细：\(gauge)")
                        }
                    }
                }
            } catch {
                say("diagnostics_relay：启动失败 —— \(error.localizedDescription)")
            }

            let gauge = api.batteryGauge(device)
            if gauge.isEmpty {
                say("结果：GasGauge 也拿不到")
            } else {
                let design = LibraryService.int(gauge["DesignCapacity"])
                let full = LibraryService.int(gauge["FullChargeCapacity"])
                let cycles = LibraryService.int(gauge["CycleCount"])
                say("结果：设计 \(design) mAh · FullChargeCapacity \(full) · 循环 \(cycles)")
            }
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// 3) House Arrest：哪些 App 的容器能打开，Documents 有多大
    // MARK: - Airlock（电脑往设备导入照片的官方通道）

    /// 只读探测：Airlock 服务在 iOS 26.7 上还开不开。
    ///
    /// 为什么值得单独做一条探针：往 `/DCIM` 塞文件 Phone 的照片库**不会收录**
    /// （相册读的是 Photos.sqlite，不扫目录）。iMazing 的「Import Photos To Device」
    /// 走的是 `Airlock` 服务（字符串表里 `Airlock` / `/Airlock/Photo/` / `13.0.5.13`
    /// 挨在一起，是 iTunes ATH 同步通道）。这条通了，压缩版才能真的回到手机相册。
    ///
    /// 本探针**只读**，不写任何文件。
    private static func probeAirlock() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice()
            try api.openSession(device)
            let info = api.info(device)
            say("设备：\(info.name) · \(info.productType) · iOS \(info.productVersion)")

            // 对照组：com.apple.afc 一定可用，证明会话本身没问题
            let candidates = [
                "com.apple.afc",
                "Airlock",
                "com.apple.mobile.airlock",
                "com.apple.airlock",
                "com.apple.afc2"
            ]

            defer { api.stopSession(device) }

            for name in candidates {
                do {
                    let afc = try api.openServiceAFC(device, name: name)
                    defer { api.closeAFC(afc) }

                    let root = (try? api.listDirectory(afc, path: "/")) ?? []
                    say("✅ \(name)：AFC 已建立，根目录 \(root.count) 项 \(root.prefix(12))")

                    // Airlock 的根下面应该能看到 Photo / Book / Media 这几种投递目录
                    for sub in ["/Photo", "/Photo/", "/Book", "/Media", "/Airlock", "/DCIM"] {
                        if let entries = try? api.listDirectory(afc, path: sub), !entries.isEmpty {
                            say("    \(sub) → \(entries.count) 项 \(entries.prefix(8))")
                        }
                    }

                    // Airlock 被禁之后的两条备选：iTunes 照片同步目录、照片修改队列
                    if name == "com.apple.afc" {
                        let paths = ["/Photos", "/PhotoData",
                                     "/PhotoData/Mutations", "/PhotoData/Mutations/DCIM",
                                     "/PhotoData/Metadata", "/PhotoData/Metadata/DCIM",
                                     "/PhotoData/internal", "/PhotoData/OutgoingTemp"]
                        for sub in paths {
                            if let entries = try? api.listDirectory(afc, path: sub) {
                                say("    [备选] \(sub) → \(entries.count) 项 \(entries.prefix(20))")
                            } else {
                                say("    [备选] \(sub) → 打不开")
                            }
                        }
                        // Mutations/DCIM 里如果有设备自己写的样例，直接把它读出来看格式
                        var dirs = ["/PhotoData/Mutations/DCIM", "/PhotoData/Metadata/DCIM"]
                        if let entries = try? api.listDirectory(afc, path: "/PhotoData/Mutations/DCIM") {
                            dirs += entries.prefix(2).map { "/PhotoData/Mutations/DCIM/" + $0 }
                        }
                        if let entries = try? api.listDirectory(afc, path: "/PhotoData/Metadata/DCIM") {
                            dirs += entries.prefix(2).map { "/PhotoData/Metadata/DCIM/" + $0 }
                        }
                        for sub in dirs {
                            guard let entries = try? api.listDirectory(afc, path: sub) else {
                                say("    [深挖] \(sub) → 打不开"); continue
                            }
                            say("    [深挖] \(sub) → \(entries.count) 项 \(entries.prefix(8))")
                            for e in entries.prefix(2) {
                                let p = sub + "/" + e
                                let size = api.entrySize(afc, path: p)
                                say("      [文件] \(p) = \(size) 字节")
                                if size > 0, let data = try? api.readFile(afc, path: p, limit: 8192) {
                                    let head = data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
                                    say("         hex: \(head)")
                                    // plist 可能整份是文本，直接打出来
                                    let text = String(decoding: data.prefix(3000), as: UTF8.self)
                                    let clean = text.replacingOccurrences(of: "\n", with: " ⏎ ")
                                    say("         ascii: \(clean)")
                                }
                            }
                        }
                    }
                } catch {
                    say("❌ \(name)：\(error.localizedDescription)")
                }
            }
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    // MARK: - 实况照片的文件布局

    /// 确认实况照片的**视频分量**到底躺在哪：
    /// 假设是「同目录、同 basename、扩展名 .MOV」，但这个必须对着真机验一次，
    /// 否则预览播不出来时不知道该怀疑代码还是该怀疑文件名规则。
    private static func probeLiveFiles() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice()
            try api.openSession(device)
            let afc = try api.openAFC(device)
            defer {
                // 会话必须关：只 closeAFC 不 stopSession 会在设备上漏一串会话，
                // 漏够了设备开始拒连（实测「配对校验失败」就是这么来的）
                api.closeAFC(afc)
                api.stopSession(device)
            }

            let folders = (try? api.listDirectory(afc, path: "/DCIM")) ?? []
            say("DCIM 子目录 \(folders.count) 个")

            var photoStems: [String: String] = [:]   // basename → 目录
            var videoStems: [String: String] = [:]
            var paired = 0
            var unpairedLive = 0

            for folder in folders.prefix(12) {
                let path = "/DCIM/" + folder
                guard let entries = try? api.listDirectory(afc, path: path) else { continue }
                var heics: [String] = []
                var movs: [String] = []
                for name in entries {
                    let ext = (name as NSString).pathExtension.uppercased()
                    let stem = (name as NSString).deletingPathExtension
                    if ["HEIC", "JPG", "JPEG"].contains(ext) {
                        heics.append(name); photoStems[stem] = folder
                    } else if ["MOV", "MP4"].contains(ext) {
                        movs.append(name); videoStems[stem] = folder
                    }
                }
                let pairs = heics.filter { (($0 as NSString).deletingPathExtension).isEmpty == false }
                    .map { ($0 as NSString).deletingPathExtension }
                    .filter { stem in movs.contains { ($0 as NSString).deletingPathExtension == stem } }
                if !pairs.isEmpty {
                    say("  \(folder)：图 \(heics.count) / 视频 \(movs.count)，同名配对 \(pairs.count) 组 → \(pairs.prefix(3))")
                    paired += pairs.count
                }
            }

            for (stem, folder) in photoStems where videoStems[stem] != nil {
                _ = folder
            }
            unpairedLive = photoStems.keys.filter { videoStems[$0] == nil }.count
            say("总计：同名「图+视频」配对 \(paired) 组；只有图的 stem \(unpairedLive) 个")
            say("（配对 = 实况照片；只有图 = 普通照片）")
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// 端到端验「实况预览取视频分量」这条路：
    /// 从 `Photos.sqlite` 里拿一条真正的实况，按 `AppStore.loadLiveVideo` 的同一套规则
    /// 拼出 `.MOV` 路径，然后问设备这个文件在不在（`AFCFileRefOpen` 返回 0 才算对）。
    /// 拼错了这里会立刻暴露，不用等界面里"实况不动"再回头猜。
    private static func probeLiveFetch(libraryPath: String) {
        // `--fetch-library` 的参数就是主库的完整路径（旁边会有 -wal / -shm），
        // 传目录时退回拼 Photos.sqlite，两种写法都能用
        var dbPath = libraryPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: libraryPath, isDirectory: &isDir), isDir.boolValue {
            dbPath = (libraryPath as NSString).appendingPathComponent("Photos.sqlite")
        }
        guard let lib = PhotoLibraryIndex.load(dbPath: dbPath) else {
            say("读不到库：\(dbPath)（先跑 --fetch-library）")
            exit(1)
        }
        let lives = lib.allMeta.filter(\.isLive)
        say("库里实况照片 \(lives.count) 条")

        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice()
            try api.openSession(device)
            let afc = try api.openAFC(device)
            defer {
                api.closeAFC(afc)
                api.stopSession(device)
            }

            var hit = 0
            var miss = 0
            for meta in lives.prefix(20) {
                let stem = (meta.fileName as NSString).deletingPathExtension
                let dir = meta.directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let prefix = dir.uppercased().hasPrefix("DCIM") ? "/\(dir)" : "/DCIM/\(dir)"
                let paths = ["MOV", "mov", "MP4", "mp4"].map { "\(prefix)/\(stem).\($0)" }

                var opened: String?
                for path in paths {
                    var ref: UnsafeMutableRawPointer?
                    if api.openFileStatus(afc, path: path, &ref) == 0 {
                        api.closeFile(afc, ref!)
                        opened = path
                        break
                    }
                }
                if let opened {
                    hit += 1
                    if hit <= 5 {
                        let size = api.entrySize(afc, path: opened)
                        say("  ✅ \(meta.fileName) → \(opened)（\(size) 字节）")
                    }
                } else {
                    miss += 1
                    if miss <= 5 {
                        say("  ❌ \(meta.fileName) dir=\(meta.directory) 试过 \(paths.first ?? "-")")
                    }
                }
            }
            say("结果：命中 \(hit) / 未命中 \(miss)（样本 \(min(20, lives.count)) 条）")

            // 光「路径对」不等于「播得出来」：再真拉一条下来，
            // 用 AVAsset 读轨道和时长 —— 读得到，AVPlayer 才播得动。
            if let sample = lives.first {
                let stem = (sample.fileName as NSString).deletingPathExtension
                let dir = sample.directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let prefix = dir.uppercased().hasPrefix("DCIM") ? "/\(dir)" : "/DCIM/\(dir)"
                let path = "\(prefix)/\(stem).MOV"
                say("下载一条验证播放能力：\(path)")
                do {
                    let data = try api.readFile(afc, path: path, limit: 32 * 1024 * 1024)
                    let local = URL(fileURLWithPath: "/tmp/cmi-live-sample.mov")
                    try data.write(to: local)
                    let asset = AVURLAsset(url: local)
                    let duration = CMTimeGetSeconds(asset.duration)
                    let videoTracks = asset.tracks(withMediaType: .video).count
                    let audioTracks = asset.tracks(withMediaType: .audio).count
                    say("  下载 \(data.count) 字节 · 时长 \(String(format: "%.2f", duration))s"
                        + " · 视频轨 \(videoTracks) · 音频轨 \(audioTracks)")
                    if let track = asset.tracks(withMediaType: .video).first {
                        say("  画面 \(Int(track.naturalSize.width))×\(Int(track.naturalSize.height)) · 码率 \(Int(track.estimatedDataRate / 1000)) kbps")
                    }
                    let playable = asset.isPlayable && videoTracks > 0 && duration > 0
                    say(playable ? "  ✅ AVPlayer 能播" : "  ❌ AVPlayer 播不了")
                } catch {
                    say("  下载失败：\(error.localizedDescription)")
                }
            }
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    // MARK: - 上传探针（PTP）

    /// 试 `ICCameraDevice.requestUploadFile` —— 能不能把文件写回 iPhone。
    /// 这是 Airlock 被禁之后唯一的「走协议、不是硬塞文件」的路。
    private static func probeUpload() {
        let bridge = PTPBridge()
        let sem = DispatchSemaphore(value: 0)
        var result = "没有回调"

        bridge.start()
        say("正在等设备枚举（6 秒）…")

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            Task {
                let url = makeProbeJPEG()
                say("测试文件：\(url.path)（\(apiFileSize(url)) 字节）")
                let message = await bridge.probeUpload(fileURL: url)
                result = message
                sem.signal()
            }
        }

        while sem.wait(timeout: .now() + 0.1) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        say("上传结果：\(result)")
        bridge.stop()
        exit(0)
    }

    /// 造一张一眼就能认出来的测试图，万一真传进去了要能立刻认出来删掉
    private static func makeProbeJPEG() -> URL {
        let url = URL(fileURLWithPath: "/tmp/cmi-upload-probe.jpg")
        let size = NSSize(width: 320, height: 320)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(origin: .zero, size: size).fill()
        let text = "CMI PROBE" as NSString
        text.draw(at: NSPoint(x: 60, y: 150),
                  withAttributes: [.font: NSFont.boldSystemFont(ofSize: 28),
                                   .foregroundColor: NSColor.white])
        image.unlockFocus()

        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
            try? data.write(to: url)
        }
        return url
    }

    private static func apiFileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
    }

    private static func probeHouse() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice()
            try api.openSession(device)

            // 直接在探针里读应用清单，避免跨 MainActor 等异步
            var apps: [(bundleID: String, name: String)] = []
            if let service = try? api.openService(device, name: "com.apple.mobile.installation_proxy") {
                let response = api.serviceRequest(service, [
                    "Command": "Lookup",
                    "ClientOptions": ["Attributes": ["CFBundleDisplayName", "ApplicationType"]]
                ])
                let result = (response["LookupResult"] as? [String: Any]) ?? response
                for (key, value) in result {
                    guard key.contains("."), let info = value as? [String: Any] else { continue }
                    let name = (info["CFBundleDisplayName"] as? String)
                        ?? (info["CFBundleName"] as? String) ?? key
                    apps.append((key, name))
                }
            }
            apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            say("应用数：\(apps.count)")

            var opened = 0
            var totalBytes: Int64 = 0
            // 先拿几个「确定装在手机上、且开了文件共享」的 App 试，排除系统 App 的干扰
            let known = ["com.tencent.xin", "com.apple.DocumentsApp", "com.apple.mobileslideshow"]
                + apps.map(\.bundleID).filter { $0.hasPrefix("com.") && !$0.hasPrefix("com.apple.") }.prefix(6)
            for bundleID in known {
                let (reply, ok) = api.houseArrestRaw(device,
                                                     command: ["Command": "VendContainer", "Identifier": bundleID])
                say("  \(bundleID) -> ok=\(ok) reply=\(reply)")
                if ok { opened += 1 }
            }
            for app in apps.prefix(40) {
                guard let afc = try? api.openHouseArrest(device, bundleID: app.bundleID, container: true) else {
                    continue
                }
                opened += 1
                let entries = (try? api.listDirectory(afc, path: "/")) ?? []
                var bytes: Int64 = 0
                for entry in entries {
                    bytes += api.entrySize(afc, path: "/" + entry)
                }
                totalBytes += bytes
                say("  \(app.name)（\(app.bundleID)）：顶层 \(entries.count) 项，\(bytes) 字节")
            }
            say("可打开容器：\(opened) 个，合计 \(totalBytes) 字节")
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    // MARK: - 写入探针（AFC 写 DCIM）

    /// 先验证「能不能往 DCIM 写文件」。写一个纯文本，读回来，再删掉，
    /// 不碰任何照片。通过之后才谈照片写回。
    private static func probeWrite() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 10)
            try api.openSession(device)
            let afc = try api.openAFC(device)
            defer { api.closeAFC(afc); api.stopSession(device) }

            let dir = "/DCIM/142APPLE"
            let test = dir + "/cmi-write-test.txt"
            let data = Data("cleanmyiphone write probe\n".utf8)
            let written = try api.writeFile(afc, path: test, data: data)
            say("写入 \(written) 字节 → \(test)")

            let names = (try? api.listDirectory(afc, path: dir)) ?? []
            say("目录里能看到：\(names.contains("cmi-write-test.txt"))")

            let back = (try? api.readFile(afc, path: test, limit: 4096)) ?? Data()
            say("读回：\(String(decoding: back, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")

            let test2 = dir + "/cmi-write-test-2.txt"
            do {
                try api.renamePath(afc, from: test, to: test2)
                let after = (try? api.listDirectory(afc, path: dir)) ?? []
                say("改名成功：\(after.contains("cmi-write-test-2.txt"))")
                try? api.removePath(afc, path: test2)
            } catch {
                say("改名失败：\(error.localizedDescription)")
                try? api.removePath(afc, path: test)
            }
            say("测试文件已清理")

            let pdDir = "/PhotoData"
            let pdTest = pdDir + "/cmi-write-test.txt"
            do {
                let n = try api.writeFile(afc, path: pdTest, data: data)
                say("PhotoData 写入 \(n) 字节")
                let names = (try? api.listDirectory(afc, path: pdDir)) ?? []
                say("PhotoData 能看到：\(names.contains("cmi-write-test.txt"))")
                try? api.removePath(afc, path: pdTest)
                say("PhotoData 测试文件已清理")

            let a = dir + "/cmi-replace-a.txt"
            let b = dir + "/cmi-replace-b.txt"
            _ = try? api.writeFile(afc, path: a, data: Data("A".utf8))
            _ = try? api.writeFile(afc, path: b, data: Data("B".utf8))
            do {
                try api.renamePath(afc, from: a, to: b)
                let back = (try? api.readFile(afc, path: b, limit: 16)) ?? Data()
                say("替换测试：\(String(decoding: back, as: UTF8.self))（期望 A）")
            } catch {
                say("替换测试失败：\(error.localizedDescription)")
            }
            try? api.removePath(afc, path: a)
            try? api.removePath(afc, path: b)
            } catch {
                say("PhotoData 写入失败：\(error.localizedDescription)")
            }
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// 换格式试验：把指定的 PNG 取回本地 → 转成 HEIC（保留元数据）→
    /// 写到同一 DCIM 目录下的新文件名，不覆盖原图。
    private static func probeConvert() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 10)
            try api.openSession(device)
            let afc = try api.openAFC(device)
            defer { api.closeAFC(afc); api.stopSession(device) }

            let srcPath = "/DCIM/142APPLE/IMG_2045.PNG"
            let dir = "/DCIM/142APPLE"
            let dstName = "IMG_2045 (1).HEIC"
            let dstPath = dir + "/" + dstName

            let work = URL(fileURLWithPath: "/tmp/cmi-exp", isDirectory: true)
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let local = work.appendingPathComponent("IMG_2045.PNG")
            if !FileManager.default.fileExists(atPath: local.path) {
                let n = try api.downloadFile(afc, path: srcPath, to: local)
                say("下载 \(n) 字节 → \(local.path)")
            }

            guard let source = CGImageSourceCreateWithURL(local as CFURL, nil),
                  CGImageSourceGetCount(source) > 0 else {
                say("ImageIO 打不开原图")
                exit(1)
            }
            var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?) as? [CFString: Any] ?? [:]
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                say("解码失败")
                exit(1)
            }

            let out = work.appendingPathComponent("IMG_2045 (1).HEIC")
            try? FileManager.default.removeItem(at: out)
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL,
                                                             UTType.heic.identifier as CFString, 1, nil) else {
                say("建输出失败")
                exit(1)
            }
            props[kCGImageDestinationLossyCompressionQuality] = 0.8
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                say("编码失败")
                exit(1)
            }
            let outSize = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? NSNumber)?.int64Value ?? 0
            let srcSize = ((try? FileManager.default.attributesOfItem(atPath: local.path))?[.size] as? NSNumber)?.int64Value ?? 0
            say("转换完成：\(srcSize) → \(outSize) 字节（\(out.path)）")

            let written = try api.writeFile(afc, path: dstPath, data: try Data(contentsOf: out))
            say("写入设备 \(written) 字节 → \(dstPath)")
            let names = (try? api.listDirectory(afc, path: dir)) ?? []
            say("目录里能看到：\(names.contains(dstName))")
            say("下一步：打开手机「照片」，看这张新图有没有被收进相册；没有就说明只写 DCIM 不够。")
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// 把 `/tmp/cmi-edit-backup/Photos.sqlite` 写回手机（`--probe-edit --restore`）。
    /// 只在「写回之后手机上不对劲」时用：备份是改库前那一刻的原库。
    private static func restoreEditBackup() {
        let backup = URL(fileURLWithPath: "/tmp/cmi-edit-backup/Photos.sqlite")
        guard let data = try? Data(contentsOf: backup), !data.isEmpty else {
            say("找不到备份：\(backup.path)（重启过电脑的话 /tmp 已经被清了）")
            exit(1)
        }
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 10)
            try api.openSession(device)
            let afc = try api.openAFC(device)
            let info = api.info(device)
            say("还原：\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
            let temp = "/PhotoData/Photos.sqlite.new"
            try? api.removePath(afc, path: temp)
            let written = try api.writeFile(afc, path: temp, data: data)
            guard written == Int64(data.count) else {
                say("写入字节数不对：\(written) / \(data.count)")
                api.closeAFC(afc); api.stopSession(device)
                exit(1)
            }
            try api.renamePath(afc, from: temp, to: "/PhotoData/Photos.sqlite")
            try? api.removePath(afc, path: "/PhotoData/Photos.sqlite-wal")
            try? api.removePath(afc, path: "/PhotoData/Photos.sqlite-shm")
            api.closeAFC(afc); api.stopSession(device)
            try? PhotoDaemon.restartLibrary(udid: info.identifier)
            say("已还原到备份，相册服务已重启")
            say("⚠️ 还原会丢掉备份之后新拍的照片行。确认没问题后删掉备份：rm -rf /tmp/cmi-edit-backup")
        } catch {
            say("还原失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// 元数据编辑探针：**收藏 + 新建相簿 + 移动** 三件事一次验完。
    ///
    /// 默认只改本地副本（打印改完的样子），**不写回设备**；加 `--apply` 才真写回并重启相册服务。
    /// 参数：
    ///   `--file IMG_1234.HEIC`  目标资产（默认取库里第一条普通照片）
    ///   `--create 名字`          新建相簿名（默认 `cmi测试`）
    ///   `--album 源相簿名`       从哪个相簿移出（可省；省了就是"加入"）
    ///   `--apply`               写回手机
    private static func probeEdit() {
        func argument(_ name: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: name),
                  index + 1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[index + 1]
        }
        let wantedFile = argument("--file")
        let createTitle = argument("--create") ?? "cmi测试"
        let sourceTitle = argument("--album")
        let apply = CommandLine.arguments.contains("--apply")
        let restore = CommandLine.arguments.contains("--restore")

        if restore {
            restoreEditBackup()
            return
        }

        say("元数据编辑探针：\(apply ? "会写回设备" : "只改本地副本")")

        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 10)
            try api.openSession(device)
            let afc = try api.openAFC(device)
            let info = api.info(device)
            let dir = URL(fileURLWithPath: "/tmp/cmi-edit")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in ["Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm"] {
                let remote = "/PhotoData/" + name
                let expected = api.entrySize(afc, path: remote)
                guard expected > 0 else { continue }
                let local = dir.appendingPathComponent(name)
                let bytes = try api.downloadFile(afc, path: remote, to: local, expected: expected)
                say("\(name)：\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
            }
            let dbPath = dir.appendingPathComponent("Photos.sqlite").path

            // 真写之前留一份原库：这台手机的照片库是用户唯一的，出问题要能退回。
            if apply {
                let backup = URL(fileURLWithPath: "/tmp/cmi-edit-backup")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
                for name in ["Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm"] {
                    let source = dir.appendingPathComponent(name)
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    try? FileManager.default.copyItem(at: source, to: backup.appendingPathComponent(name))
                }
                say("原库已备份到 /tmp/cmi-edit-backup/")
                say("要退回：同一条命令加 --restore（重启前有效）")
            }

            guard let index = PhotoLibraryIndex.load(dbPath: dbPath) else {
                say("库读不出来（quick_check 没过）")
                api.closeAFC(afc); api.stopSession(device)
                exit(1)
            }
            say("库：\(index.metaByFile.count) 条资产 / \(index.albums.count) 个相簿")

            // 表结构自检：新建相簿要动 `ZGENERICALBUM` 和 `Z_PRIMARYKEY`，
            // 这两张表的真实长相必须打出来（`Z_PRIMARYKEY.Z_NAME` 到底有没有、叫什么）。
            if let db = SQLiteDB(path: dbPath) {
                say("Z_PRIMARYKEY 列：\(db.columns(of: "Z_PRIMARYKEY").joined(separator: ", "))")
                for row in db.rows("SELECT * FROM Z_PRIMARYKEY ORDER BY Z_ENT") {
                    say("  ent=\(row.int("Z_ENT"))"
                        + "  name=\(row.string("Z_NAME") ?? "—")"
                        + "  super=\(row.int("Z_SUPER"))"
                        + "  max=\(row.int("Z_MAX"))")
                }
                for table in ["ZGENERICALBUM"] {
                    let ddl = db.rows("SELECT sql FROM sqlite_master WHERE type='table' AND name='\(table)'")
                        .first?.string("sql") ?? "—"
                    say("\(table) DDL：\(ddl)")
                }
                for row in db.rows("SELECT ZKIND, COUNT(*) AS c FROM ZGENERICALBUM GROUP BY ZKIND ORDER BY c DESC") {
                    say("  相簿 ZKIND=\(row.int("ZKIND")) 有 \(row.int("c")) 个")
                }
                if let sample = db.rows("""
                    SELECT Z_PK, ZTITLE, ZKIND, ZCACHEDCOUNT, Z_OPT,
                           typeof(ZUUID) AS UUIDTYPE, ZCREATIONDATE
                    FROM ZGENERICALBUM
                    WHERE ZKIND = 2 AND ZTITLE IS NOT NULL AND TRIM(ZTITLE) <> ''
                    ORDER BY Z_PK LIMIT 1
                    """).first {
                    say("  样本相簿：pk=\(sample.int("Z_PK"))「\(sample.string("ZTITLE") ?? "—")」"
                        + " kind=\(sample.int("ZKIND")) count=\(sample.int("ZCACHEDCOUNT"))"
                        + " ZUUID 类型=\(sample.string("UUIDTYPE") ?? "—")"
                        + " 创建=\(sample.double("ZCREATIONDATE"))")
                }
                if let join = try? PhotosDBEdit.joinTable(db) {
                    let ddl = db.rows("SELECT sql FROM sqlite_master WHERE type='table' AND name='\(join.name)'")
                        .first?.string("sql") ?? "—"
                    say("关联表 \(join.name)（\(join.albumColumn) / \(join.assetColumn)）：\(ddl)")
                }
            }

            let target: PhotoLibraryIndex.Meta
            if let wantedFile, let hit = index.meta(for: wantedFile) {
                target = hit
            } else if let first = index.metaByFile.values
                .filter({ !$0.isVideo && !$0.isTrashed && $0.pk > 0 })
                .min(by: { $0.pk < $1.pk }) {
                target = first
                if wantedFile != nil { say("没找到 \(wantedFile!)，改用 \(first.fileName)") }
            } else {
                say("库里没有可用的照片")
                api.closeAFC(afc); api.stopSession(device)
                exit(1)
            }
            say("目标：\(target.fileName)（pk \(target.pk)，\(target.directory)）当前收藏 = \(target.isFavorite)")

            // `--cleanup`：把前面几次验证留下的痕迹清掉 —— 测试相簿、加进 CapCut 的那张、以及翻转过的收藏位。
            if CommandLine.arguments.contains("--cleanup") {
                var ops: [PhotosDBEdit.Op] = []
                for album in index.albums where album.title.hasPrefix("cmi") {
                    say("删测试相簿「\(album.title)」(pk \(album.id)，\(album.count) 张)")
                    ops.append(.deleteAlbum(pk: album.id))
                }
                if let capcut = index.albums.first(where: { $0.title == "CapCut" }) {
                    say("把这张从「CapCut」里拿掉（恢复成空相簿）")
                    ops.append(.membership(assetPK: target.pk, album: .existing(capcut.id), present: false))
                }
                ops.append(.favorite(pk: target.pk, value: false))
                let (edited, result) = try PhotosDBEdit.apply(dbPath: dbPath, workDir: dir, ops: ops)
                say("清理：删相簿 \(result.deletedAlbums.count) 本 · 成员 \(result.memberships) 处")
                if let check = SQLiteDB(path: edited) {
                    let left = check.rows("""
                        SELECT COUNT(*) AS c FROM ZGENERICALBUM WHERE ZTITLE LIKE 'cmi%'
                        """).first?.int("c") ?? -1
                    say("  库里剩下的 cmi 相簿：\(left)")
                    let fav = check.rows("SELECT ZFAVORITE AS c FROM ZASSET WHERE Z_PK=\(target.pk)")
                        .first?.int("c") ?? -1
                    say("  \(target.fileName) 的 ZFAVORITE = \(fav)")
                }
                guard apply else {
                    say("只改了本地副本，没写回设备。加 --apply 才真清。")
                    api.closeAFC(afc); api.stopSession(device)
                    exit(0)
                }
                try writeBackEdit(api: api, afc: afc, path: edited, udid: info.identifier)
                say("已清理并写回；去手机上看那两个测试相簿是不是没了")
                try? FileManager.default.removeItem(at: dir)
                exit(0)
            }

            // `--conform`：一次验两件事 ——
            // ① 往「早就存在的空相簿」里加一张（隔离出「成员关系写法」对不对）
            // ② 用「照正常用户相簿改过的行」新建一本再加一张（隔离出「新建相簿那一行」对不对）
            if CommandLine.arguments.contains("--conform") {
                let conformTitle = argument("--create") ?? "cmi测试2"
                var ops: [PhotosDBEdit.Op] = [
                    .createAlbum(tempID: -2, title: conformTitle),
                    .membership(assetPK: target.pk, album: .created(-2), present: true)
                ]
                let existing = index.albums.first { $0.title == "CapCut" }
                    ?? index.albums.first { $0.kind == 2 && $0.count == 0 }
                if let existing {
                    say("同时把这张加进已有空相簿「\(existing.title)」(pk \(existing.id))")
                    ops.append(.membership(assetPK: target.pk, album: .existing(existing.id), present: true))
                } else {
                    say("库里没有「已有空相簿」，只验新建那本")
                }
                let (edited, result) = try PhotosDBEdit.apply(dbPath: dbPath, workDir: dir, ops: ops)
                say("改完：新建 \(result.createdAlbums[-2] ?? 0) · 成员 \(result.memberships) 处")
                if let check = SQLiteDB(path: edited) {
                    for row in check.rows("""
                        SELECT Z_PK, ZTITLE, ZCACHEDCOUNT, ZCUSTOMSORTKEY, Z_OPT, ZSTARTDATE, ZENDDATE
                        FROM ZGENERICALBUM WHERE Z_PK = \(result.createdAlbums[-2] ?? -1)
                        """) {
                        say("  新相簿：pk=\(row.int("Z_PK"))「\(row.string("ZTITLE") ?? "—")」"
                            + " count=\(row.int("ZCACHEDCOUNT")) sortKey=\(row.int("ZCUSTOMSORTKEY"))"
                            + " opt=\(row.int("Z_OPT")) 起=\(row.double("ZSTARTDATE")) 止=\(row.double("ZENDDATE"))")
                    }
                    if let join = try? PhotosDBEdit.joinTable(check) {
                        for row in check.rows("""
                            SELECT \(join.albumColumn) AS a, \(join.assetColumn) AS s, Z_FOK_3ASSETS AS f
                            FROM "\(join.name)" WHERE \(join.assetColumn) = \(target.pk)
                            """) {
                            say("  成员：相簿 \(row.int("a")) · 资产 \(row.int("s")) · FOK=\(row.int("f"))")
                        }
                    }
                }
                guard apply else {
                    say("只改了本地副本（\(edited)），没写回设备。加 --apply 才真写。")
                    api.closeAFC(afc); api.stopSession(device)
                    exit(0)
                }
                try writeBackEdit(api: api, afc: afc, path: edited, udid: info.identifier)
                say("去手机上看两件事：")
                say("  ① 「CapCut」相簿里有没有这张照片（验成员写法）")
                say("  ② 新相簿「\(conformTitle)」里有没有这张照片（验新建那行）")
                try? FileManager.default.removeItem(at: dir)
                exit(0)
            }

            var ops: [PhotosDBEdit.Op] = [
                .createAlbum(tempID: -1, title: createTitle),
                .favorite(pk: target.pk, value: !target.isFavorite),
                .membership(assetPK: target.pk, album: .created(-1), present: true)
            ]
            if let sourceTitle, let source = index.albums.first(where: { $0.title == sourceTitle }) {
                say("从相簿「\(sourceTitle)」(\(source.id)，\(source.count) 张) 移出")
                ops.append(.membership(assetPK: target.pk, album: .existing(source.id), present: false))
            } else if sourceTitle != nil {
                say("警告：库里没有叫「\(sourceTitle!)」的相簿，只做加入")
            }

            let (edited, result) = try PhotosDBEdit.apply(dbPath: dbPath, workDir: dir, ops: ops)
            say("改完：新建相簿 \(result.createdAlbums.values.map(String.init).joined(separator: ", "))"
                + " · 收藏 \(result.favorites) 处 · 成员 \(result.memberships) 处")
            if !result.missingAssets.isEmpty {
                say("跳过（资产不在了）：\(result.missingAssets)")
            }

            if let check = SQLiteDB(path: edited) {
                for row in check.rows("""
                    SELECT Z_PK, ZTITLE, ZKIND, ZCACHEDCOUNT FROM ZGENERICALBUM
                    ORDER BY Z_PK DESC LIMIT 4
                    """) {
                    say("  相簿 pk=\(row.int("Z_PK"))  「\(row.string("ZTITLE") ?? "—")」"
                        + "  kind=\(row.int("ZKIND"))  count=\(row.int("ZCACHEDCOUNT"))")
                }
                let fav = check.rows("SELECT ZFAVORITE AS c FROM ZASSET WHERE Z_PK=\(target.pk)")
                    .first?.int("c") ?? -1
                say("  \(target.fileName) 的 ZFAVORITE = \(fav)")
                if let join = try? PhotosDBEdit.joinTable(check),
                   let newPK = result.createdAlbums[-1] {
                    let members = check.rows("""
                        SELECT \(join.assetColumn) AS c FROM \(join.name)
                        WHERE \(join.albumColumn) = \(newPK)
                        """)
                    say("  新相簿成员表（\(join.name)）里有 \(members.count) 行")
                }
                say("  quick_check：\(check.quickCheck() ? "ok" : "失败")")
            }

            guard apply else {
                say("没有写回设备。确认上面的结果对，再加 --apply 跑一次就真写。")
                api.closeAFC(afc); api.stopSession(device)
                try? FileManager.default.removeItem(at: dir)
                exit(0)
            }

            let data = try Data(contentsOf: URL(fileURLWithPath: edited))
            say("写回：\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
            let temp = "/PhotoData/Photos.sqlite.new"
            try? api.removePath(afc, path: temp)
            let written = try api.writeFile(afc, path: temp, data: data)
            guard written == Int64(data.count) else {
                say("写入字节数不对：\(written) / \(data.count)")
                api.closeAFC(afc); api.stopSession(device)
                exit(1)
            }
            try api.renamePath(afc, from: temp, to: "/PhotoData/Photos.sqlite")
            try? api.removePath(afc, path: "/PhotoData/Photos.sqlite-wal")
            try? api.removePath(afc, path: "/PhotoData/Photos.sqlite-shm")
            say("已替换 Photos.sqlite（旧 WAL/SHM 已清）")
            api.closeAFC(afc); api.stopSession(device)

            do {
                try PhotoDaemon.restartLibrary(udid: info.identifier)
                say("相册服务已重启")
            } catch {
                say("重启相册失败：\(error.localizedDescription)（重启 iPhone 后生效）")
            }
            say("去手机上确认三件事：① 相簿里多出「\(createTitle)」"
                + "② 这张照片在它里面 ③ 这张照片的爱心状态翻转了")
            try? FileManager.default.removeItem(at: dir)
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// 写回之后「相簿有了、里面是空的」时用：把设备上**现在的**库读回来，
    /// 对比「新建相簿那一行 / 成员关联行 / 收藏位」到底留下了什么、被改回什么。
    private static func probeEditCheck() {
        func argument(_ name: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: name),
                  index + 1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[index + 1]
        }
        let title = argument("--create") ?? "cmi测试"
        let file = argument("--file") ?? "IMG_0017.JPG"
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 10)
            try api.openSession(device)
            let afc = try api.openAFC(device)
            let dir = URL(fileURLWithPath: "/tmp/cmi-edit-check")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in ["Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm"] {
                let remote = "/PhotoData/" + name
                let expected = api.entrySize(afc, path: remote)
                guard expected > 0 else { continue }
                _ = try api.downloadFile(afc, path: remote,
                                         to: dir.appendingPathComponent(name), expected: expected)
            }
            api.closeAFC(afc); api.stopSession(device)

            let dbPath = dir.appendingPathComponent("Photos.sqlite").path
            guard let db = SQLiteDB(path: dbPath) else { say("库打不开"); exit(1) }

            say("关联表候选（`Z_%ASSETS`）：")
            for table in db.tables(matching: "Z_%ASSETS") {
                let count = db.rows("SELECT COUNT(*) AS c FROM \"\(table)\"").first?.int("c") ?? 0
                say("  \(table) 行数 \(count) · 列 \(db.columns(of: table).joined(separator: ", "))")
            }

            say("最近 8 个相簿：")
            let recent = db.rows("""
                SELECT Z_PK, Z_ENT, ZTITLE, ZKIND, ZCACHEDCOUNT, ZCACHEDPHOTOSCOUNT, ZCACHEDVIDEOSCOUNT,
                       ZTRASHEDSTATE, ZCLOUDLOCALSTATE, ZCLOUDDELETESTATE, Z_OPT, ZCREATIONDATE
                FROM ZGENERICALBUM ORDER BY Z_PK DESC LIMIT 8
                """)
            for a in recent {
                say("  pk=\(a.int("Z_PK")) ent=\(a.int("Z_ENT"))「\(a.string("ZTITLE") ?? "—")」"
                    + " kind=\(a.int("ZKIND")) cached=\(a.int("ZCACHEDCOUNT"))"
                    + " 照片=\(a.int("ZCACHEDPHOTOSCOUNT")) 视频=\(a.int("ZCACHEDVIDEOSCOUNT"))"
                    + " trashed=\(a.int("ZTRASHEDSTATE")) cloudLocal=\(a.int("ZCLOUDLOCALSTATE"))"
                    + " cloudDel=\(a.int("ZCLOUDDELETESTATE")) opt=\(a.int("Z_OPT"))")
            }

            let our = db.rows("SELECT Z_PK FROM ZGENERICALBUM WHERE ZTITLE = \(quoteSQL(title)) ORDER BY Z_PK DESC")
            say("叫「\(title)」的相簿：\(our.map { String($0.int("Z_PK")) }.joined(separator: ", "))")
            if let join = try? PhotosDBEdit.joinTable(db) {
                for album in our {
                    let id = album.int("Z_PK")
                    let rows = db.rows("""
                        SELECT * FROM "\(join.name)" WHERE \(join.albumColumn) = \(id) LIMIT 5
                        """)
                    say("  pk=\(id) 在 \(join.name) 里有 \(rows.count) 行")
                    for row in rows { say("    \(dumpRow(db, table: join.name, row: row))") }
                }
                // 拿一个正常相簿对照：它的成员行长什么样
                if let normal = db.rows("""
                    SELECT Z_PK, ZTITLE FROM ZGENERICALBUM
                    WHERE ZKIND = 2 AND ZTITLE IS NOT NULL AND ZTITLE <> \(quoteSQL(title))
                    ORDER BY ZCACHEDCOUNT DESC LIMIT 1
                    """).first {
                    let id = normal.int("Z_PK")
                    say("对照相簿「\(normal.string("ZTITLE") ?? "—")」pk=\(id)：")
                    for row in db.rows("SELECT * FROM \"\(join.name)\" WHERE \(join.albumColumn) = \(id) LIMIT 3") {
                        say("    \(dumpRow(db, table: join.name, row: row))")
                    }
                }

                // 目标照片到底在哪些相簿里（确认我们只动了自己那一个）
                say("照片 \(file) 出现在这些相簿里：")
                for row in db.rows("""
                    SELECT j.\(join.albumColumn) AS a, j.Z_FOK_3ASSETS AS f, g.ZTITLE AS t
                    FROM "\(join.name)" j LEFT JOIN ZGENERICALBUM g ON g.Z_PK = j.\(join.albumColumn)
                    WHERE j.\(join.assetColumn) = (
                        SELECT Z_PK FROM ZASSET WHERE ZFILENAME = \(quoteSQL(file)) LIMIT 1
                    )
                    """) {
                    say("    相簿 \(row.int("a"))「\(row.string("t") ?? "—")」 Z_FOK=\(row.int("f"))")
                }
            }

            // 触发器：`ZGENERICALBUM` / `Z_33ASSETS` 上如果有维护别的东西的触发器，
            // 我们「摘掉 → 插入 → 装回」就不算数了（装回时不会补跑）。
            say("相关触发器：")
            for row in db.rows("""
                SELECT name, tbl_name, sql FROM sqlite_master
                WHERE type = 'trigger'
                  AND tbl_name IN ('ZGENERICALBUM', 'Z_33ASSETS', 'Z_32KEYASSETS', 'ZASSET')
                LIMIT 10
                """) {
                say("  \(row.string("tbl_name") ?? "?") · \(row.string("name") ?? "?")")
                say("    \(row.string("sql") ?? "—")")
            }

            // 整行对比：我们新建的 vs 一个正常用户相簿，逐列看差在哪儿
            for name in [title, "滑蛋牛肉饭"] {
                guard let row = db.rows("""
                    SELECT * FROM ZGENERICALBUM WHERE ZTITLE = \(quoteSQL(name)) ORDER BY Z_PK DESC
                    """).first else { continue }
                say("整行「\(name)」：")
                say("  \(dumpRow(db, table: "ZGENERICALBUM", row: row))")
            }

            // 封面/关键资产：相簿列表里的那张缩略图，看看正常相簿有没有、我们有没有
            for table in db.tables(matching: "Z_%KEYASSETS") {
                say("\(table)（封面）里我们的相簿：")
                let cols = db.columns(of: table)
                guard let albumCol = cols.first(where: { $0.hasSuffix("ALBUMSBEINGKEYASSETS") }) else { continue }
                for row in db.rows("""
                    SELECT * FROM "\(table)" WHERE \(albumCol) IN (
                        SELECT Z_PK FROM ZGENERICALBUM WHERE ZTITLE IN (\(quoteSQL(title)), '滑蛋牛肉饭')
                    ) LIMIT 6
                    """) {
                    say("    \(dumpRow(db, table: table, row: row))")
                }
            }

            say("照片 \(file) 的收藏位：")
            for row in db.rows("""
                SELECT Z_PK, ZFAVORITE, ZTRASHEDSTATE, ZHIDDEN FROM ZASSET
                WHERE ZFILENAME = \(quoteSQL(file))
                """) {
                say("  pk=\(row.int("Z_PK")) ZFAVORITE=\(row.int("ZFAVORITE"))"
                    + " trashed=\(row.int("ZTRASHEDSTATE")) hidden=\(row.int("ZHIDDEN"))")
            }

            for table in ["ZALBUMLIST", "Z_2ALBUMS", "Z_2ASSETS"] where db.tables(matching: table).contains(table) {
                say("\(table)：")
                for row in db.rows("SELECT * FROM \"\(table)\" LIMIT 8") {
                    say("    \(dumpRow(db, table: table, row: row))")
                }
            }

            say("这个库里的相簿总数：\(db.rows("SELECT COUNT(*) AS c FROM ZGENERICALBUM").first?.int("c") ?? 0)")
            try? FileManager.default.removeItem(at: dir)
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// 把改好的库写回设备，并让相册服务重读（`--probe-edit` 和 `--conform` 共用）。
    private static func writeBackEdit(api: MobileDeviceAPI,
                                      afc: UnsafeMutableRawPointer,
                                      path: String,
                                      udid: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        say("写回：\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
        let temp = "/PhotoData/Photos.sqlite.new"
        try? api.removePath(afc, path: temp)
        let written = try api.writeFile(afc, path: temp, data: data)
        guard written == Int64(data.count) else {
            throw NSError(domain: "cmi.edit", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "写入字节数不对：\(written) / \(data.count)"
            ])
        }
        try api.renamePath(afc, from: temp, to: "/PhotoData/Photos.sqlite")
        try? api.removePath(afc, path: "/PhotoData/Photos.sqlite-wal")
        try? api.removePath(afc, path: "/PhotoData/Photos.sqlite-shm")
        say("已替换 Photos.sqlite（旧 WAL/SHM 已清）")
        do {
            try PhotoDaemon.restartLibrary(udid: udid)
            say("相册服务已重启")
        } catch {
            say("重启相册失败：\(error.localizedDescription)（重启 iPhone 后生效）")
        }
    }

    private static func quoteSQL(_ value: String) -> String {        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// 探针用：不管列是什么类型，都尽力打成一个字符串。
    private static func dumpRow(_ db: SQLiteDB, table: String, row: SQLiteDB.Row) -> String {
        db.columns(of: table).map { column in
            if let text = row.string(column) { return "\(column)=\(text)" }
            let number = row.int64(column)
            if number != 0 { return "\(column)=\(number)" }
            let real = row.double(column)
            if real != 0 { return "\(column)=\(real)" }
            return "\(column)=0"
        }.joined(separator: "  ")
    }

    /// 把改好的 Photos.sqlite 写回手机：先写 .new，再原子替换，最后清掉旧 WAL/SHM。
    /// 目标库来自 /tmp/cmi-exp/db/Photos.sqlite（已经 checkpoint 成单文件）。
    private static func probeDbWrite() {
        do {
            let url = URL(fileURLWithPath: "/tmp/cmi-exp/db/Photos.sqlite")
            let data = try Data(contentsOf: url)
            say("待写 \(data.count) 字节")
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 10)
            try api.openSession(device)
            let afc = try api.openAFC(device)
            defer { api.closeAFC(afc); api.stopSession(device) }

            let tmp = "/PhotoData/Photos.sqlite.new"
            try? api.removePath(afc, path: tmp)
            let written = try api.writeFile(afc, path: tmp, data: data)
            say("写入 \(written) 字节 → \(tmp)")
            try api.renamePath(afc, from: tmp, to: "/PhotoData/Photos.sqlite")
            say("已替换 Photos.sqlite")
            try? api.removePath(afc, path: "/PhotoData/Photos.sqlite-wal")
            try? api.removePath(afc, path: "/PhotoData/Photos.sqlite-shm")
            say("已清理旧 WAL/SHM")
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// 通过 diagnostics_relay 重启手机，让 photolibraryd 重新加载数据库。
    private static func probeReboot() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 10)
            try api.openSession(device)
            guard let service = try? api.openService(device, name: "com.apple.mobile.diagnostics_relay") else {
                say("diagnostics_relay 打不开")
                exit(1)
            }
            let response = api.serviceRequest(service, ["Request": "Restart"])
            say("重启请求已发送：\(response)")
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// 验收：新文件在不在、多大、缩略图有没有生成。
    private static func probeVerify() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 10)
            try api.openSession(device)
            let afc = try api.openAFC(device)
            defer { api.closeAFC(afc); api.stopSession(device) }

            let file = "/DCIM/142APPLE/IMG_2045 (1).HEIC"
            say("文件大小：\(api.entrySize(afc, path: file)) 字节")
            let thumbDir = "/PhotoData/Thumbnails/V2/DCIM/142APPLE/IMG_2045 (1).HEIC"
            let names = (try? api.listDirectory(afc, path: thumbDir)) ?? []
            say("缩略图目录：\(names.count) 项 \(names.prefix(8))")
            for n in names where n.lowercased().hasSuffix(".jpg") {
                say("  \(n) = \(api.entrySize(afc, path: thumbDir + "/" + n)) 字节")
            }
            let original = "/DCIM/142APPLE/IMG_2045.PNG"
            say("原图大小：\(api.entrySize(afc, path: original)) 字节")
        } catch {
            say("失败：\(error.localizedDescription)")
        }
        exit(0)
    }

    /// IMG_2046 换格式：实况 HEIC 静态帧 → JPEG，写到同目录新文件名。
    private static func probeConvert2046() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 10)
            try api.openSession(device)
            let afc = try api.openAFC(device)
            defer { api.closeAFC(afc); api.stopSession(device) }

            let srcPath = "/DCIM/142APPLE/IMG_2046.HEIC"
            let dir = "/DCIM/142APPLE"
            let dstName = "IMG_2046 (1).JPG"
            let dstPath = dir + "/" + dstName

            let work = URL(fileURLWithPath: "/tmp/cmi-exp", isDirectory: true)
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let local = work.appendingPathComponent("IMG_2046.HEIC")
            if !FileManager.default.fileExists(atPath: local.path) {
                let n = try api.downloadFile(afc, path: srcPath, to: local)
                say("下载 \(n) 字节 → \(local.path)")
            }

            guard let source = CGImageSourceCreateWithURL(local as CFURL, nil),
                  CGImageSourceGetCount(source) > 0 else {
                say("ImageIO 打不开原图")
                exit(1)
            }
            var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?) as? [CFString: Any] ?? [:]
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                say("解码失败")
                exit(1)
            }

            let out = work.appendingPathComponent(dstName)
            try? FileManager.default.removeItem(at: out)
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL,
                                                             UTType.jpeg.identifier as CFString, 1, nil) else {
                say("建输出失败")
                exit(1)
            }
            props[kCGImageDestinationLossyCompressionQuality] = 0.7
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                say("编码失败")
                exit(1)
            }
            let outSize = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? NSNumber)?.int64Value ?? 0
            let srcSize = ((try? FileManager.default.attributesOfItem(atPath: local.path))?[.size] as? NSNumber)?.int64Value ?? 0
            let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            say("转换完成：HEIC \(srcSize) → JPG \(outSize) 字节，像素 \(image.width)×\(image.height)，orientation=\(orientation)")

            let written = try api.writeFile(afc, path: dstPath, data: try Data(contentsOf: out))
            say("写入设备 \(written) 字节 → \(dstPath)")
            let names = (try? api.listDirectory(afc, path: dir)) ?? []
            say("目录里能看到：\(names.contains(dstName))")
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// 验收 IMG_2046 的 JPEG 和缩略图。
    private static func probeVerify2046() {
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 10)
            try api.openSession(device)
            let afc = try api.openAFC(device)
            defer { api.closeAFC(afc); api.stopSession(device) }

            let file = "/DCIM/142APPLE/IMG_2046 (1).JPG"
            say("文件大小：\(api.entrySize(afc, path: file)) 字节")
            let thumbDir = "/PhotoData/Thumbnails/V2/DCIM/142APPLE/IMG_2046 (1).JPG"
            let names = (try? api.listDirectory(afc, path: thumbDir)) ?? []
            say("缩略图目录：\(names.count) 项 \(names.prefix(8))")
            for n in names where n.lowercased().hasSuffix(".jpg") {
                say("  \(n) = \(api.entrySize(afc, path: thumbDir + "/" + n)) 字节")
            }
        } catch {
            say("失败：\(error.localizedDescription)")
        }
        exit(0)
    }

    // MARK: - 批量转换 CLI

    private static func convertBatch() {
        let arguments = CommandLine.arguments
        func value(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let dbPath = value("--db"), let udid = value("--udid") else {
            say("用法：--convert-batch --db <Photos.sqlite> --udid <UDID> [--ids 1,2] [--limit 8] [--ratio 0.6] [--format heic|jpeg|png] [--quality 0.8] [--dry-run]")
            exit(1)
        }

        let ids = value("--ids")?.split(separator: ",").compactMap { Int($0) }
        let limit = Int(value("--limit") ?? "") ?? (ids?.count ?? 8)
        let ratio = Double(value("--ratio") ?? "") ?? 0.6
        let quality = Double(value("--quality") ?? "") ?? 0.8
        let format = ConversionProfile.Format(rawValue: value("--format") ?? "") ?? .heic
        let dryRun = arguments.contains("--dry-run")

        let items = loadConversionItems(dbPath: dbPath, ids: ids, limit: limit)
        guard !items.isEmpty else {
            say("没有可转换的图片（db=\(dbPath)）")
            exit(1)
        }
        say("待转换 \(items.count) 张 · \(Int((ratio * 100).rounded()))% · \(format.displayName) · Q\(Int((quality * 100).rounded()))\(dryRun ? " · dry-run（不写设备、不改库）" : "")")

        do {
            let engine = try PhotoConversionEngine(
                udid: udid,
                workDir: URL(fileURLWithPath: "/tmp/cmi-convert", isDirectory: true))
            let result = engine.run(
                items: items,
                profile: ConversionProfile(ratio: ratio, format: format, quality: quality),
                writeFiles: !dryRun,
                writeDB: !dryRun,
                restartDaemon: !dryRun
            ) { progress in
                say("[\(progress.phase)] \(progress.completed)/\(progress.total) \(progress.current)")
            }
            say("完成 \(result.records.count) 张 · 失败 \(result.failures.count) 张 · 用时 \(String(format: "%.1f", result.elapsed))s")
            for failure in result.failures {
                say("  失败：\(failure.name) — \(failure.reason)")
            }
            if let db = result.dbPath {
                _ = db
                say("数据库已改完（临时库已清理）")
            }
            if result.daemonRestarted {
                say("assetsd 已重启")
            }
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    private static func loadConversionItems(dbPath: String,
                                            ids: [Int]?,
                                            limit: Int) -> [ConversionItem] {
        guard let db = SQLiteDB(path: dbPath, writable: false) else { return [] }
        var whereClause = "ZKIND=0 AND ZTRASHEDSTATE=0"
        if let ids, !ids.isEmpty {
            whereClause += " AND Z_PK IN (\(ids.map(String.init).joined(separator: ",")))"
        }
        let sql = """
        SELECT Z_PK, ZUUID, ZDIRECTORY, ZFILENAME, ZUNIFORMTYPEIDENTIFIER,
               ZWIDTH, ZHEIGHT, ZKINDSUBTYPE, ZPLAYBACKSTYLE, ZISDETECTEDSCREENSHOT,
               ZFAVORITE, ZKIND
        FROM ZASSET
        WHERE \(whereClause)
        ORDER BY ZDATECREATED DESC
        LIMIT \(max(1, limit));
        """
        return db.rows(sql).compactMap { row in
            let name = row.string("ZFILENAME") ?? ""
            guard !name.isEmpty else { return nil }
            let subtype = row.int("ZKINDSUBTYPE")
            let playback = row.int("ZPLAYBACKSTYLE")
            return ConversionItem(
                pk: row.int("Z_PK"),
                uuid: row.string("ZUUID") ?? "",
                directory: row.string("ZDIRECTORY") ?? "",
                fileName: name,
                uti: row.string("ZUNIFORMTYPEIDENTIFIER") ?? "",
                width: row.int("ZWIDTH"),
                height: row.int("ZHEIGHT"),
                subtype: subtype,
                playbackStyle: playback,
                isScreenshot: row.int("ZISDETECTEDSCREENSHOT") == 1 || subtype == 10,
                isLive: subtype == 2 && playback == 3,
                isVideo: row.int("ZKIND") == 1,
                favorite: row.int("ZFAVORITE") == 1,
                byteSize: 0
            )
        }
    }

    private static func probeDaemon() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--udid"),
              index + 1 < arguments.count else {
            say("用法：--probe-daemon --udid <UDID>")
            exit(1)
        }
        do {
            try PhotoDaemon.restartLibrary(udid: arguments[index + 1])
            say("assetsd 已重启")
        } catch {
            say("失败：\(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    private static func probeCheck() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--name"),
              index + 1 < arguments.count else {
            say("用法：--probe-check --name <DCIM 文件名>")
            exit(1)
        }
        let name = arguments[index + 1]
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 10)
            try api.openSession(device)
            let afc = try api.openAFC(device)
            defer { api.closeAFC(afc); api.stopSession(device) }

            let file = "/DCIM/142APPLE/" + name
            let bytes = api.entrySize(afc, path: file)
            say("\(name)：\(bytes) 字节")

            let local = URL(fileURLWithPath: "/tmp/cmi-check-\(UUID().uuidString).heic")
            let downloaded = try api.downloadFile(afc, path: file, to: local)
            if let source = CGImageSourceCreateWithURL(local as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                say("解码：\(downloaded) 字节，\(image.width)×\(image.height)")
            } else {
                say("解码失败")
            }
            try? FileManager.default.removeItem(at: local)

            let thumbDir = "/PhotoData/Thumbnails/V2/DCIM/142APPLE/" + name
            let names = (try? api.listDirectory(afc, path: thumbDir)) ?? []
            say("缩略图：\(names)")
            for entry in names where entry.lowercased().hasSuffix(".jpg") {
                say("  \(entry) = \(api.entrySize(afc, path: thumbDir + "/" + entry)) 字节")
            }
        } catch {
            say("失败：\(error.localizedDescription)")
        }
        exit(0)
    }
}
