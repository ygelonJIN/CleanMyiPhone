import AppKit
import Foundation

/// 真机探针：不启动界面，直接枚举一次并打印结果。
/// 用法：`cleanmyiphone --probe`
enum Probe {

    private static let logURL = URL(fileURLWithPath: "/tmp/cmi-probe.log")

    /// 子进程入口：把 /PhotoData/Photos.sqlite 拉到指定路径。
    /// 单独成进程，是因为这根 AFC 读大文件的调用会随机把堆写坏，
    /// 放在主 App 进程里会把界面一起带崩。
    private static func fetchLibrary(to path: String) {
        var code: Int32 = 1
        defer { exit(code) }
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice()
            try api.openSession(device)
            let afc = try api.openAFC(device)

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
            if planned <= 0 { planned = 1 }
            print("SIZE 0 \(planned)")
            fflush(stdout)

            var done: Int64 = 0
            func report(_ bytes: Int64) {
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

    static func runIfRequested() {
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
}
