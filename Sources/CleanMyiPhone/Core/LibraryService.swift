import Foundation

/// 从设备取 `Photos.sqlite` 并解析成索引。
/// 整段跑在独立线程上：MobileDevice 的通知回调依赖该线程的 RunLoop。
final class LibraryService {

    struct AppInfo: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let version: String
        let isSystem: Bool
    }

    struct DeviceStats {
        var totalCapacity: Int64 = 0
        var available: Int64 = 0
        var appBytes: Int64 = 0
        var appCount: Int = 0
        var appNames: [String] = []
        var appList: [AppInfo] = []
        var deviceName: String = ""
        var serial: String = ""
        var udid: String = ""
        var phoneNumber: String = ""
        var carrier: String = ""
        var batteryLevel: Int = 0
        var batteryCharging: Bool = false
        var productType: String = ""
        var productVersion: String = ""

        // 型号号码 / 系统构建号
        var modelNumber: String = ""
        var buildVersion: String = ""

        // 电池细项（diagnostics_relay 的 GasGauge，拿不到就是 0）
        var batteryDesign: Int = 0          // DesignCapacity，设计最大电量 mAh
        var batteryRawMax: Int = 0          // 有效最大电量 mAh（由健康百分比折算）
        var batteryHealthPercent: Int = 0   // FullChargeCapacity，实测这个字段给的就是百分比
        var batteryCycles: Int = 0          // CycleCount，循环次数

        /// 连接方式：我们现在只走 USB（Wi-Fi 同步没做）
        /// 系统分区（iOS 本体所在，只读快照）：实测 7.93 GB，可用 0
        var systemCapacity: Int64 = 0
        var systemAvailable: Int64 = 0

        var connection: String = "USB"

        var isEmpty: Bool { totalCapacity == 0 && appBytes == 0 }

        /// 电池健康度：优先用系统给的百分比，否则用有效/设计算
        var batteryHealth: Double? {
            if batteryHealthPercent > 0 { return Double(batteryHealthPercent) / 100 }
            guard batteryDesign > 0, batteryRawMax > 0 else { return nil }
            return Double(batteryRawMax) / Double(batteryDesign)
        }
    }

    struct Snapshot {
        let index: PhotoLibraryIndex
        let stats: DeviceStats
    }

    enum ServiceError: LocalizedError {
        case timeout
        case nonIndex
        case locked
        case incomplete(received: Int64, expected: Int64)

        var errorDescription: String? {
            switch self {
            case .timeout:
                return "设备没有响应，检查是否已解锁并点过「信任」"
            case .nonIndex:
                return "照片库读取失败"
            case .locked:
                return "iPhone 已锁屏，请先解锁屏幕再点刷新"
            case .incomplete(let received, let expected):
                let got = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                let all = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
                return "读取相册索引时连接中断，只读到 \(got) / \(all)。保持手机解锁并插着数据线，点刷新重试"
            }
        }
    }

    static var cacheURL: URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["CMI_CACHE_DIR"] {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("cleanmyiphone", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("Photos.sqlite")
    }

    /// 主线程执行（MobileDevice 的通知只往主 RunLoop 投递），
    /// 下载按 256 KB 分片，每 16 片让出一次，界面不卡。
    @MainActor
    /// 用上次抓好的本地快照（默认 6 小时内有效），避免每次启动都重下 296MB
    static func loadCachedIndex(maxAge: TimeInterval = 6 * 3600) -> PhotoLibraryIndex? {
        let url = cacheURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < maxAge else { return nil }
        guard let index = PhotoLibraryIndex.load(dbPath: url.path), !index.isEmpty else { return nil }
        return index
    }

    static func fetch(progress: @escaping (Double) -> Void,
                      onBytes: @escaping (Int64, Int64) -> Void = { _, _ in }) async throws -> Snapshot {
        try await fetchOnMain(progress: progress, onBytes: onBytes)
    }

    /// 只探一下锁屏状态（不读库）。锁屏时读 296 MB 只会卡到超时，不如直接让用户去解锁。
    static func isDeviceLocked() -> Bool {
        guard let api = try? MobileDeviceAPI(),
              let device = try? api.firstDevice(timeout: 3) else { return false }
        guard (try? api.openSession(device)) != nil else { return false }
        return api.isLocked(device)
    }

    /// 有没有真机插着（只看通知，不开会话）
    static func isDeviceAvailable(timeout: TimeInterval = 2) -> Bool {
        guard let api = try? MobileDeviceAPI() else { return false }
        return (try? api.firstDevice(timeout: timeout)) != nil
    }

    @MainActor
    private static func fetchOnMain(progress: @escaping (Double) -> Void,
                                    onBytes: @escaping (Int64, Int64) -> Void) async throws -> Snapshot {
        progress(0.01)

        // 锁屏检查放在最前面：这时还没起子进程，失败得快、提示得准
        if Self.isDeviceLocked() {
            throw ServiceError.locked
        }

        // 相册库下载交给子进程：
        // 主进程里 ImageCaptureCore 占着设备会话，AFC 打开/读取会失败或崩，
        // 而子进程没有 PTP，能正常读。子进程内部也会对「写了一半」的库做重试。
        let url = cacheURL
        let staging = URL(fileURLWithPath: url.path + ".new")
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.removeItem(atPath: staging.path + "-wal")
        try? FileManager.default.removeItem(atPath: staging.path + "-shm")
        progress(0.04)

        // 先抓到临时文件；成功才替换缓存，失败就继续用上一次的可用快照
        let check = try await runFetchHelper(to: staging.path, onBytes: onBytes)
        Self.dbg("helper check=\(check)")
        progress(0.90)

        // 主库 + WAL + SHM 一起转正，缺一个本地打开就会 malformed
        if check > 0 {
            for suffix in ["", "-wal", "-shm"] {
                let from = staging.path + suffix
                guard FileManager.default.fileExists(atPath: from) else { continue }
                try? FileManager.default.removeItem(atPath: url.path + suffix)
                try? FileManager.default.copyItem(atPath: from, toPath: url.path + suffix)
            }
        }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: staging.path + suffix)
        }

        guard let index = PhotoLibraryIndex.load(dbPath: url.path), !index.isEmpty else {
            throw ServiceError.nonIndex
        }
        Self.dbg("index assets=\(index.metaByFile.count) albums=\(index.albums.count)")
        progress(0.95)

        let stats = try await fetchDeviceStats()
        progress(1)
        return Snapshot(index: index, stats: stats)
    }

    /// 拉起子进程下载并校验相册库，返回 ZASSET 行数（>0 表示成功）。
    /// 子进程边读边打 `SIZE <总量>` / `PROGRESS <已读>`，这里实时转发给界面。
    @MainActor
    private static func runFetchHelper(to path: String,
                                       onBytes: @escaping (Int64, Int64) -> Void) async throws -> Int {
        guard let executable = Bundle.main.executableURL else { throw ServiceError.nonIndex }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--fetch-library", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()

        let pump = OutputPump(handle: pipe.fileHandleForReading)
        pump.onLine = { line in
            guard line.hasPrefix("PROGRESS ") || line.hasPrefix("SIZE ") else { return }
            let fields = line.split(separator: " ")
            guard fields.count >= 3,
                  let done = Int64(fields[1]),
                  let total = Int64(fields[2]), total > 0 else { return }
            Task { @MainActor in onBytes(done, total) }
        }
        pump.start()

        // 看门狗：15 秒内连 SIZE 都没打出来，说明库根本打不开，别让界面干等
        let start = Date()
        while process.isRunning && Date().timeIntervalSince(start) < 15 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if pump.sawSize { break }
        }
        let sawSize = pump.sawSize

        let deadline = Date().addingTimeInterval(180)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if process.isRunning {
            process.terminate()
            pump.stop()
            throw ServiceError.timeout
        }

        let output = pump.stop()
        var check = 0
        for line in output.split(separator: "\n") where line.hasPrefix("CHECK ") {
            check = Int(line.dropFirst(6)) ?? 0
        }
        Self.dbg("helper exit=\(process.terminationStatus) check=\(check) sawSize=\(sawSize)")

        // 子进程没能给出 SIZE 又没读到东西：多半是锁屏 / 会话被抢
        if check == 0, !sawSize, Self.isDeviceLocked() {
            throw ServiceError.locked
        }
        return check
    }

    /// 子进程 stdout 的按行读取器：AFC 下载在子进程里跑，父进程只收进度
    private final class OutputPump: @unchecked Sendable {
        private let handle: FileHandle
        private let lock = NSLock()
        private var buffer = Data()
        private var shown: [String] = []
        private var sawSizeLine = false
        var onLine: (@Sendable (String) -> Void)?

        init(handle: FileHandle) { self.handle = handle }

        var sawSize: Bool {
            lock.lock(); defer { lock.unlock() }
            return sawSizeLine
        }

        func start() {
            handle.readabilityHandler = { [weak self] fh in
                let chunk = fh.availableData
                guard let self, !chunk.isEmpty else { return }
                self.feed(chunk)
            }
        }

        private func feed(_ chunk: Data) {
            var lines: [String] = []
            lock.lock()
            buffer.append(chunk)
            while let index = buffer.firstIndex(of: 0x0A) {
                let slice = buffer[buffer.startIndex..<index]
                let line = String(decoding: slice, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(line)
                if line.hasPrefix("SIZE ") { sawSizeLine = true }
                buffer.removeSubrange(buffer.startIndex...index)
            }
            shown.append(contentsOf: lines)
            let callback = onLine
            lock.unlock()
            for line in lines where !line.isEmpty { callback?(line) }
        }

        @discardableResult
        func stop() -> String {
            handle.readabilityHandler = nil
            lock.lock()
            let rest = String(decoding: buffer, as: UTF8.self)
            if !rest.isEmpty { shown.append(rest) }
            let text = shown.joined(separator: "\n")
            lock.unlock()
            return text
        }
    }

    /// 环境变量只读一次：ProcessInfo.environment 在多线程里反复取会出问题
    private static let debugEnabled = ProcessInfo.processInfo.environment["CMI_DEBUG"] != nil

    private static func dbg(_ line: String) {
        guard debugEnabled else { return }
        let url = URL(fileURLWithPath: "/tmp/cmi-library.log")
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    private static func readStats(api: MobileDeviceAPI, device: UnsafeMutableRawPointer) -> DeviceStats {
        var stats = DeviceStats()
        stats.deviceName = api.deviceString(device, key: "DeviceName") ?? ""
        stats.productType = api.deviceString(device, key: "ProductType") ?? ""
        stats.productVersion = api.deviceString(device, key: "ProductVersion") ?? ""
        stats.serial = api.deviceString(device, key: "SerialNumber") ?? ""
        stats.udid = api.deviceString(device, key: "UniqueDeviceID") ?? ""
        stats.phoneNumber = api.deviceString(device, key: "PhoneNumber")
            ?? api.deviceString(device, key: "phone_number")
            ?? ""
        if let bundles = api.allValues(device)["CarrierBundleInfoArray"] as? [[String: Any]],
           let bundleID = bundles.first?["CFBundleIdentifier"] as? String {
            stats.carrier = Self.carrierName(from: bundleID)
        }
        stats.batteryLevel = api.deviceInt(device, domain: "com.apple.mobile.battery", key: "BatteryCurrentCapacity")
        stats.batteryCharging = api.deviceInt(device, domain: "com.apple.mobile.battery", key: "BatteryIsCharging") == 1

        // 型号号码（RegionInfo 里，个别系统在基础域）
        let base = api.allValues(device)
        stats.modelNumber = api.deviceString(device, key: "ModelNumber")
            ?? (base["RegionInfo"] as? [String: Any])?["ModelNumber"] as? String
            ?? ""
        stats.buildVersion = api.deviceString(device, key: "BuildVersion") ?? ""

        // 电池细项：走 diagnostics_relay 的 GasGauge，
        // 实测只有 DesignCapacity（mAh）、FullChargeCapacity（百分比）、CycleCount，没有温度
        let gauge = api.batteryGauge(device)
        if !gauge.isEmpty {
            stats.batteryDesign = Self.int(gauge["DesignCapacity"])
            stats.batteryCycles = Self.int(gauge["CycleCount"])
            let full = Self.int(gauge["FullChargeCapacity"])
            if full > 0, full <= 100 {
                stats.batteryHealthPercent = full
                if stats.batteryDesign > 0 {
                    stats.batteryRawMax = Int(Double(stats.batteryDesign) * Double(full) / 100)
                }
            } else if full > 0 {
                // 有些系统这一项直接给 mAh
                stats.batteryRawMax = full
            }
        }
        // 真实容量与可用：TotalDiskCapacity 是整机，AmountDataAvailable 才是可用
        stats.totalCapacity = api.deviceValue(device, domain: "com.apple.disk_usage", key: "TotalDiskCapacity")
        if stats.totalCapacity == 0 {
            stats.totalCapacity = api.deviceValue(device, domain: "com.apple.disk_usage", key: "TotalDataCapacity")
        }
        stats.systemCapacity = api.deviceValue(device, domain: "com.apple.disk_usage", key: "TotalSystemCapacity")
        stats.systemAvailable = api.deviceValue(device, domain: "com.apple.disk_usage", key: "TotalSystemAvailable")
        stats.available = api.deviceValue(device, domain: "com.apple.disk_usage", key: "AmountDataAvailable")
        if stats.available == 0 {
            stats.available = api.deviceValue(device, domain: "com.apple.disk_usage", key: "TotalDataAvailable")
        }

        if let service = try? api.openService(device, name: "com.apple.mobile.installation_proxy") {
            let response = api.serviceRequest(service, [
                "Command": "Lookup",
                "ClientOptions": ["Attributes": ["StaticDiskUsage", "DynamicDiskUsage"]]
            ])
            let result = (response["LookupResult"] as? [String: Any]) ?? response
            var total: Int64 = 0
            var count = 0
            var names: [String] = []
            var infos: [AppInfo] = []
            for (key, value) in result {
                guard key.contains("."), let info = value as? [String: Any] else { continue }
                let display = (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? key
                names.append(display)
                let version = (info["CFBundleShortVersionString"] as? String) ?? ""
                let type = (info["ApplicationType"] as? String) ?? ""
                // 只有 ApplicationType == "User" 才是用户装的 App；
                // "System" 和 "Hidden"（CarPlay、Bridge 这类）都不该出现在默认列表里
                infos.append(AppInfo(bundleID: key, name: display, version: version,
                                     isSystem: type != "User"))
                let staticBytes = (info["StaticDiskUsage"] as? NSNumber)?.int64Value ?? 0
                let dynamicBytes = (info["DynamicDiskUsage"] as? NSNumber)?.int64Value ?? 0
                total += staticBytes + dynamicBytes
                count += 1
            }
            stats.appBytes = total
            stats.appCount = count
            stats.appNames = names.sorted()
            stats.appList = infos.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return stats
    }

    /// 只读设备信息与容量（不碰 AFC）：相册库读不到时概览也能用
    @MainActor
    static func fetchDeviceStats() async throws -> DeviceStats {
        let api = try MobileDeviceAPI.shared()
        let device = try api.firstDevice(timeout: 10)
        try api.openSession(device)
        return readStats(api: api, device: device)
    }

    static func carrierName(from bundleID: String) -> String {
        let lowered = bundleID.lowercased()
        if lowered.contains("chinamobile") { return "中国移动" }
        if lowered.contains("chinaunicom") { return "中国联通" }
        if lowered.contains("chinatelecom") { return "中国电信" }
        if lowered.contains("china") { return "中国运营商" }
        // 退回到 bundle id 里的运营商名
        let parts = bundleID.split(separator: ".")
        return parts.count > 3 ? String(parts[3]).replacingOccurrences(of: "_cn", with: "") : "—"
    }

    /// IORegistry 里的数值都是 NSNumber，也可能是字符串
    static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) ?? 0 }
        return 0
    }
}
