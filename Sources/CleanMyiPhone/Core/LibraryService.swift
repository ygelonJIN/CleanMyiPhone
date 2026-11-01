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

        // 系统状态（基础域）
        var activationState: String = ""    // ActivationState，Activated / Unactivated
        var cpuArchitecture: String = ""    // CPUArchitecture，arm64e
        var region: String = ""             // RegionInfo，国家 + 区域码
        var timeZone: String = ""           // TimeZone
        var isPaired: Bool = true           // 会话建立时 AMDeviceValidatePairing 通过了才算
        var deviceLocked: Bool = false      // PasswordProtected / DeviceLocked

        // 电池细项（diagnostics_relay 的 GasGauge，拿不到就是 0）
        var batteryDesign: Int = 0          // DesignCapacity，设计最大电量 mAh
        var batteryRawMax: Int = 0          // 有效最大电量 mAh（由健康百分比折算）
        var batteryHealthPercent: Int = 0   // FullChargeCapacity，实测这个字段给的就是百分比
        var batteryCycles: Int = 0          // CycleCount，循环次数

        // com.apple.mobile.battery 里这几个键「有/无」本身是信息，用 nil 区分「没有这个键」和「关」
        var lowPowerMode: Bool? = nil       // BatterySaverModeEnabled / LowPowerModeEnabled
        var externalConnected: Bool? = nil  // ExternalConnected，是否插着线
        var fullyCharged: Bool? = nil       // FullyCharged，是否已充满

        /// IORegistry 电池节点里的 Temperature（原始值，单位随系统变），只用于日志/后续探针
        var batteryTemperatureCenti: Int = 0

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

        /// 健康度分级（Apple 口径 80% 以下属于建议维修）
        var batteryHealthGrade: String? {
            guard let health = batteryHealth else { return nil }
            if health >= 0.9 { return "优秀" }
            if health >= 0.8 { return "良好" }
            if health >= 0.6 { return "一般" }
            return "建议维修"
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
        case channelClosed
        case incomplete(received: Int64, expected: Int64)

        var errorDescription: String? {
            switch self {
            case .timeout:
                return "读相册索引超时，设备没响应。点「重新读取」重试"
            case .nonIndex:
                return "照片库读取失败"
            case .locked:
                return "iPhone 已锁屏，请先解锁屏幕再点刷新"
            case .channelClosed:
                return "手机的文件通道被系统关掉了（AFC 无响应）。拔插一次数据线、必要时重启 iPhone，再点「重新读取」"
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
            base = TraceRegistry.dataDirectory
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("Photos.sqlite")
    }

    /// 主线程执行（MobileDevice 的通知只往主 RunLoop 投递），
    /// 下载按 256 KB 分片，每 16 片让出一次，界面不卡。
    ///
    /// **不做快照**（2026-11 定）：四件套只作中转，读完进内存就立刻删掉。
    /// 原来那个「6 小时内复用」的 `loadCachedIndex` 已经删了 —— 它和零痕迹直接冲突，
    /// 而且勾着「自动清空」时启动第一步就把文件删了，等于从来没命中过。
    ///
    /// 把这一次的落盘删干净：主库 + WAL + SHM + 缩略图配置，外加子进程留下的暂存。
    static func purgeSnapshotFiles() {
        let url = cacheURL
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(atPath: url.path + suffix)
            try? fm.removeItem(atPath: url.path + ".new" + suffix)
        }
        try? fm.removeItem(at: url.deletingLastPathComponent()
            .appendingPathComponent("thumbnailConfiguration"))
    }

    static func fetch(progress: @escaping (Double) -> Void,
                      onBytes: @escaping (Int64, Int64) -> Void = { _, _ in },
                      onFile: @escaping (String) -> Void = { _ in }) async throws -> Snapshot {
        try await fetchOnMain(progress: progress, onBytes: onBytes, onFile: onFile)
    }

    /// 只探一下锁屏状态（不读库）。锁屏时读 296 MB 只会卡到超时，不如直接让用户去解锁。
    static func isDeviceLocked() -> Bool {
        guard let api = try? MobileDeviceAPI(),
              let device = try? api.firstDevice(timeout: 3) else { return false }
        guard (try? api.openSession(device)) != nil else { return false }
        // 用完必须 stopSession。这个方法在失败路径上会被反复调用（通道探针、
        // 解锁轮询每 2 秒一次），只 open 不 stop 就是在设备上漏 lockdownd 会话；
        // 漏够多了设备开始拒连，表现就是「手机的文件通道被系统关掉了」。
        defer { api.stopSession(device) }
        return api.isLocked(device)
    }

    /// 清掉上一轮残留的 `--fetch-library` 辅助进程。
    /// 它不随父进程退出（主进程被 kill 后会被 launchd 收养），
    /// 几个叠在一起就互相抢 AFC，表现是「读相册索引卡几分钟」。
    static func killStrayHelpers() {
        // 先礼：SIGTERM 让子进程自己关 AFC、关会话再退（返回值 1 = 本来就没残留）
        let soft = runPkill(["-f", "--", "--fetch-library"])
        guard soft == 0 else { return }        // 没有残留，连等都不用等
        // 给足 2.5 秒，和 stopHelper 一个标准。400 ms 就 -9 等于把「优雅收尾」
        // 变成一次硬杀：卡在 AFC 调用里的子进程被打死后，设备侧 afcd 会留半截连接。
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            usleep(100_000)
            // 第二次 SIGTERM 查询：pkill 的返回值取反就是「还剩几个」
            let still = runPkill(["-0", "-f", "--", "--fetch-library"])
            if still != 0 { break }
        }
        // 后兵：还在的就是真卡死了，只能硬杀（并且要接受通道可能变脏）
        let hard = runPkill(["-9", "-f", "--", "--fetch-library"])
        Self.dbg("已清理残留 fetch-library 进程（SIGTERM \(soft) / SIGKILL \(hard)）")
    }

    private static func runPkill(_ arguments: [String]) -> Int32 {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        tool.arguments = arguments
        tool.standardOutput = FileHandle.nullDevice
        tool.standardError = FileHandle.nullDevice
        do {
            try tool.run()
        } catch {
            return -1
        }
        tool.waitUntilExit()
        return tool.terminationStatus
    }

    /// 有没有真机插着（只看通知，不开会话）
    static func isDeviceAvailable(timeout: TimeInterval = 2) -> Bool {
        guard let api = try? MobileDeviceAPI() else { return false }
        return (try? api.firstDevice(timeout: timeout)) != nil
    }

    @MainActor
    private static func fetchOnMain(progress: @escaping (Double) -> Void,
                                    onBytes: @escaping (Int64, Int64) -> Void,
                                    onFile: @escaping (String) -> Void) async throws -> Snapshot {
        progress(0.01)

        // 锁屏检查放在最前面：这时还没起子进程，失败得快、提示得准。
        // 但这一问本身也可能永远不返回（设备管子半死时），必须带超时。
        if await withDeviceTimeout(4, fallback: false, { Self.isDeviceLocked() }) {
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
        let check = try await runFetchHelper(to: staging.path, onBytes: onBytes, onFile: onFile)
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
            // 读不出来也要把落盘删掉：库里已经有东西进来了，文件就没用了
            purgeSnapshotFiles()
            throw ServiceError.nonIndex
        }
        Self.dbg("index assets=\(index.metaByFile.count) albums=\(index.albums.count)")
        // 索引已经在内存里了 —— 四件套立刻删，硬盘上不留这份 296 MB 的复印件
        purgeSnapshotFiles()
        progress(0.95)

        let stats = try await fetchDeviceStats()
        progress(1)
        return Snapshot(index: index, stats: stats)
    }

    /// 拉起子进程下载并校验相册库，返回 ZASSET 行数（>0 表示成功）。
    /// 子进程边读边打 `SIZE <总量>` / `PROGRESS <已读>`，这里实时转发给界面。
    @MainActor
    private static func runFetchHelper(to path: String,
                                       onBytes: @escaping (Int64, Int64) -> Void,
                                       onFile: @escaping (String) -> Void) async throws -> Int {
        guard let executable = Bundle.main.executableURL else { throw ServiceError.nonIndex }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--fetch-library", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        // 子进程 stderr 别丢：AFC 报错都写这儿，出问题时有据可查
        let errPath = "/tmp/cmi-helper-err.log"
        if ProcessInfo.processInfo.environment["CMI_DEBUG"] != nil {
            FileManager.default.createFile(atPath: errPath, contents: nil)
            if let errHandle = FileHandle(forWritingAtPath: errPath) {
                try? errHandle.truncate(atOffset: 0)
                process.standardError = errHandle
            } else {
                process.standardError = FileHandle.nullDevice
            }
        } else {
            process.standardError = FileHandle.nullDevice
        }

        // 父进程死亡兜底：这根管道当子进程的 stdin，父进程永不打字。
        // 父进程一死（哪怕被 kill -9），写端关闭，子进程 read(0,…) 立刻 EOF →
        // 自己关掉 AFC 再退。这是唯一能盖住「卡在第一个 AFC 调用上」的通路。
        let deathPipe = Pipe()
        process.standardInput = deathPipe
        var env = ProcessInfo.processInfo.environment
        env["CMI_HELPER_GUARD"] = "1"
        process.environment = env

        try process.run()

        let pump = OutputPump(handle: pipe.fileHandleForReading)
        pump.onLine = { line in
            if line.hasPrefix("FILE ") {
                let name = line.split(separator: " ").dropFirst(2).joined(separator: " ")
                Task { @MainActor in onFile(String(name)) }
                return
            }
            guard line.hasPrefix("PROGRESS ") || line.hasPrefix("SIZE ") else { return }
            let fields = line.split(separator: " ")
            guard fields.count >= 3,
                  let done = Int64(fields[1]),
                  let total = Int64(fields[2]), total > 0 else { return }
            Task { @MainActor in onBytes(done, total) }
        }
        pump.start()

        // 看门狗：30 秒内连 SIZE 都没打出来，说明库根本打不开（多半是设备被上一个
        // 残留的辅助进程占着，或刚插线设备还在忙）。以前这里只是 break 出来再等 180 秒，
        // 用户看到的就是"读相册索引 3 分钟"。
        // 15 秒太急：设备刚枚举完、AFC 首个回包常常要 10 秒以上，一急就 SIGTERM 一个
        // 正卡在 AFC 调用里的子进程，等于每次失败都赌一次「优雅收尾」。
        let start = Date()
        while process.isRunning && Date().timeIntervalSince(start) < 30 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if pump.sawSize { break }
        }
        let sawSize = pump.sawSize
        if !sawSize {
            await stopHelper(process)
            pump.stop()
            Self.dbg("helper 30s 内没给出 SIZE，已终止")
            if await withDeviceTimeout(4, fallback: false, { Self.isDeviceLocked() }) {
                throw ServiceError.locked
            }
            // helper 全程零输出时靠探针定性：是通道被设备关了，还是它自己卡住了
            switch await Self.afcChannelState() {
            case .ok:
                throw ServiceError.timeout
            case .closed, .dead:
                throw ServiceError.channelClosed
            }
        }

        // 总时限 90 秒：296 MB 实测 8 秒读完，慢速 USB 也远不到 90 秒
        let deadline = Date().addingTimeInterval(90)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if process.isRunning {
            await stopHelper(process)
            pump.stop()
            throw ServiceError.timeout
        }

        let output = pump.stop()
        var check = 0
        for line in output.split(separator: "\n") where line.hasPrefix("CHECK ") {
            check = Int(line.dropFirst(6)) ?? 0
        }
        let totals = pump.byteTotals()
        Self.dbg("helper exit=\(process.terminationStatus) check=\(check) sawSize=\(sawSize) "
                 + "read=\(totals.done)/\(totals.planned)")

        // 子进程没能给出 SIZE 又没读到东西：多半是锁屏 / 会话被抢
        if check == 0, !sawSize, await withDeviceTimeout(4, fallback: false, { Self.isDeviceLocked() }) {
            throw ServiceError.locked
        }

        // **完整性刹车**：CHECK > 0 只证明「拿到的这份主库 + WAL 自洽」，
        // 证明不了「和刚才量到的总大小一致」。AFC 半死时每个文件都会「成功地」只读回
        // 一部分：只要主库最后一次 checkpoint 之前的内容还在，quick_check 就过、
        // ZASSET 也有行 —— 于是把一份**缺了 WAL 里最新照片**的旧库当成成功快照，
        // 界面上的视频数、体积全对不上（「数据都不对」就是这么来的）。
        // 所以这里必须跟 SIZE 对账；对不上就报 incomplete，让上层保留上一份可用快照。
        if check > 0, sawSize, totals.planned > 0 {
            let short = totals.planned - totals.done
            let tolerance = max(Int64(512 * 1024), totals.planned / 200)   // 0.5% 或 512 KB
            if short > tolerance {
                Self.dbg("读取不完整：\(totals.done)/\(totals.planned)（少 \(short) 字节）")
                throw ServiceError.incomplete(received: totals.done, expected: totals.planned)
            }
        }
        return check
    }

    /// 让子进程退出：先 SIGTERM（它自己会关 AFC / 关会话再退），2.5 秒不退才 SIGKILL。
    /// 直接 `kill -9` 是上一轮把手机 AFC 通道搞坏的元凶：连接没关，设备侧 afcd 留半截，
    /// 之后所有 AFC 连接都被设备关掉。
    @MainActor
    private static func stopHelper(_ process: Process, grace: Double = 2.5) async {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            Self.dbg("helper 没理会 SIGTERM，已 SIGKILL")
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    enum AFCChannel { case ok, closed, dead }

    /// 单独探一次 AFC：能连上、能读到已知文件的大小 = 通道正常。
    /// 4 秒没回音也当通道不通 —— 设备侧 afcd 卡住时连 `openAFC` 都不回包。
    static func afcChannelState(timeout: Double = 4) async -> AFCChannel {
        await withCheckedContinuation { (continuation: CheckedContinuation<AFCChannel, Never>) in
            let once = ProbeOnce()
            Task.detached {
                once.finish(probeAFCOnce(), continuation)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.finish(.dead, continuation)
            }
        }
    }

    /// 任何「问设备一句话」的阻塞调用都必须带上这个：
    /// USB/AFC 那根管子半死的时候，`isDeviceLocked()` / `fetchDeviceStats()` 会**永远不返回**，
    /// 而且它们都在 MainActor 上 → 界面直接卡死几分钟，看起来就是「读索引读了很久」。
    /// 超时就用 fallback 继续往下走。
    static func withDeviceTimeout<T: Sendable>(_ seconds: Double,
                                               fallback: T,
                                               _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let box = OnceBox<T>()
            Task.detached {
                let value = work()
                box.finish(value, continuation)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                box.finish(fallback, continuation)
            }
        }
    }

    private final class OnceBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false

        func finish(_ value: T, _ continuation: CheckedContinuation<T, Never>) {
            lock.lock(); defer { lock.unlock() }
            guard !used else { return }
            used = true
            continuation.resume(returning: value)
        }
    }

    private static func probeAFCOnce() -> AFCChannel {
        guard let api = try? MobileDeviceAPI.shared(),
              let device = try? api.firstDevice(timeout: 3),
              (try? api.openSession(device)) != nil,
              let afc = try? api.openAFC(device) else { return .closed }
        let size = api.entrySize(afc, path: "/PhotoData/Photos.sqlite")
        api.closeAFC(afc)
        // 探针也要关会话：它跑在失败路径上，每次判断「通道通不通」都留一个会话，
        // 连续重试三次就是三个 —— 设备会开始拒连。
        api.stopSession(device)
        return size > 0 ? .ok : .closed
    }

    /// 只让第一个结果生效（探针与超时谁先到）
    private final class ProbeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false

        func finish(_ value: AFCChannel, _ continuation: CheckedContinuation<AFCChannel, Never>) {
            lock.lock(); defer { lock.unlock() }
            guard !used else { return }
            used = true
            continuation.resume(returning: value)
        }
    }

    /// 子进程 stdout 的按行读取器：AFC 下载在子进程里跑，父进程只收进度
    private final class OutputPump: @unchecked Sendable {
        private let handle: FileHandle
        private let lock = NSLock()
        private var buffer = Data()
        private var shown: [String] = []
        private var sawSizeLine = false
        /// 子进程报的「计划总字节」与「已读字节」的终值，用来对账完整性
        private var planned: Int64 = 0
        private var done: Int64 = 0
        var onLine: (@Sendable (String) -> Void)?

        init(handle: FileHandle) { self.handle = handle }

        var sawSize: Bool {
            lock.lock(); defer { lock.unlock() }
            return sawSizeLine
        }

        func byteTotals() -> (done: Int64, planned: Int64) {
            lock.lock(); defer { lock.unlock() }
            return (done, planned)
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
                // `SIZE 0 <total>` / `PROGRESS <done> <total>`
                if line.hasPrefix("SIZE ") || line.hasPrefix("PROGRESS ") {
                    let fields = line.split(separator: " ")
                    if fields.count >= 3,
                       let got = Int64(fields[1]), let total = Int64(fields[2]), total > 0 {
                        planned = max(planned, total)
                        done = max(done, got)
                    }
                }
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

        // 电池域一次取全：既省往返，也能用「键不存在」区分「关」和「没有这个键」
        let battery = api.allValues(device, domain: "com.apple.mobile.battery")
        stats.batteryLevel = Self.int(battery["BatteryCurrentCapacity"])
        stats.batteryCharging = Self.bool(battery["BatteryIsCharging"])
        stats.externalConnected = battery["ExternalConnected"].map(Self.bool)
        stats.fullyCharged = battery["FullyCharged"].map(Self.bool)
        // 低电量模式：battery 域不一定有这个键，多个候选都试
        for key in ["BatterySaverModeEnabled", "LowPowerModeEnabled", "LowPowerMode", "BatterySaverMode"]
        where battery[key] != nil {
            stats.lowPowerMode = Self.bool(battery[key])
            break
        }

        // 型号号码（RegionInfo 里，个别系统在基础域）
        let base = api.allValues(device)
        // RegionInfo 在 iOS 26 上有时是字典、有时就是一个字符串（"CH/A"），两种都要认
        let rawRegion = base["RegionInfo"]
        let regionInfo = rawRegion as? [String: Any]
        let regionString = rawRegion as? String
        stats.modelNumber = api.deviceString(device, key: "ModelNumber")
            ?? regionInfo?["ModelNumber"] as? String
            ?? ""
        stats.buildVersion = api.deviceString(device, key: "BuildVersion") ?? ""

        // 系统状态
        stats.activationState = Self.activationText(api.deviceString(device, key: "ActivationState") ?? "")
        stats.cpuArchitecture = api.deviceString(device, key: "CPUArchitecture") ?? ""
        stats.region = Self.regionText(modelNumber: stats.modelNumber,
                                       regionInfo: regionInfo,
                                       regionString: regionString)
        stats.timeZone = Self.timeZoneText(api.deviceString(device, key: "TimeZone") ?? "")
        stats.deviceLocked = api.isLocked(device)
        // 能走到这里说明 openSession 里的 AMDeviceValidatePairing 返回过 0
        stats.isPaired = true

        // 区域到底能拿到什么，一次写清楚（无照片内容，退出清空时也不动这个文件）
        let interesting = base.keys.filter {
            let k = $0.lowercased()
            return k.contains("modelnumber") || k.contains("region") || k.contains("country")
        }.sorted()
        var lines = ["ModelNumber=\(stats.modelNumber)",
                     "RegionInfo=\(rawRegion.map { "\($0)" } ?? "nil")",
                     "Region=\(stats.region)"]
        for key in interesting {
            lines.append("\(key)=\(base[key] ?? "-")")
        }
        Self.writeDeviceDump(lines)

        // 电池细项。
        //
        // 两条来源，谁有值用谁：
        // 1. diagnostics_relay 的 GasGauge：DesignCapacity（mAh）+ CycleCount 可靠，
        //    但 `FullChargeCapacity` 在这台设备上给的是 **100**（满充百分比），不是容量、也不是健康度，
        //    拿它当健康度就会永远显示 100%。只有 >1000 时才当 mAh 用。
        // 2. IORegistry 里的电池节点：NominalChargeCapacity / AppleRawMaxCapacity 才是真实可用容量，
        //    健康度 = 它 / DesignCapacity。节点是树，要按 children 递归找。
        let gauge = api.batteryGauge(device)
        let node = api.batteryNodeProps(device)
        Self.dbg("battery gauge=\(gauge) node=\(node.keys.sorted())")

        stats.batteryDesign = Self.int(node["DesignCapacity"]) > 0
            ? Self.int(node["DesignCapacity"])
            : Self.int(gauge["DesignCapacity"])
        let cycles = Self.int(node["CycleCount"]) > 0
            ? Self.int(node["CycleCount"])
            : Self.int(gauge["CycleCount"])
        stats.batteryCycles = cycles

        // 真实最大容量（mAh）：几种命名都见过
        var rawMax = 0
        for key in ["NominalChargeCapacity", "AppleRawMaxCapacity", "MaxCapacity", "FullChargeCapacity"] {
            let value = Self.int(node[key])
            if value > 1000, value <= max(stats.batteryDesign * 2, 12_000) { rawMax = value; break }
        }
        if rawMax == 0 {
            let full = Self.int(gauge["FullChargeCapacity"])
            // ≤100 的是百分比，不能当容量
            if full > 1000 { rawMax = full }
        }
        if rawMax > 0, stats.batteryDesign > 0, rawMax <= stats.batteryDesign {
            stats.batteryRawMax = rawMax
            stats.batteryHealthPercent = Int((Double(rawMax) / Double(stats.batteryDesign) * 100).rounded())
        }

        // 低电量模式：battery 域没有这个键，就在 IORegistry 节点里找带 saver/lowpower 的
        if stats.lowPowerMode == nil {
            for (key, value) in node where key.lowercased().contains("saver")
                || key.lowercased().contains("lowpower") {
                stats.lowPowerMode = Self.bool(value)
                Self.dbg("lowPowerMode 命中 \(key)=\(value)")
                break
            }
        }
        // 电池温度：IORegistry 节点里带的才是真温度（GasGauge 没有），有就顺手存下来
        if let temperature = node["Temperature"] ?? node["BatteryTemperature"] {
            let value = Self.int(temperature)
            if value > 0 {
                // 一般给的是 1/10 K 或 1/10 ℃，两种都换算不出来就按 1/100 ℃ 处理
                stats.batteryTemperatureCenti = value
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
        defer { api.stopSession(device) }
        return readStats(api: api, device: device)
    }

    /// 同上，但**不在主线程上等**，还带超时。
    /// `fetchDeviceStats()` 是 @MainActor 的，设备管子半死时它会把整个界面冻住
    /// （表现：门禁一直转，日志也不再出新行）。失败路径一律走这个。
    static func deviceStatsOffMain(timeout: Double = 6) async -> DeviceStats? {
        await withDeviceTimeout(timeout, fallback: nil) { () -> DeviceStats? in
            guard let api = try? MobileDeviceAPI.shared(),
                  let device = try? api.firstDevice(timeout: 3),
                  (try? api.openSession(device)) != nil else { return nil }
            defer { api.stopSession(device) }
            return readStats(api: api, device: device)
        }
    }

    /// 区域/型号相关的现场，写到 App Support（和电池 dump 同一个地方）
    static func writeDeviceDump(_ lines: [String]) {
        let base = TraceRegistry.dataDirectory
        DeviceFiles.makePrivateDirectory(base)
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: base.appendingPathComponent("device-dump.txt"), atomically: true, encoding: .utf8)
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

    /// 布尔值：NSNumber / "true" / "1" / "YES" 都认，缺键给 false
    static func bool(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            let lowered = text.lowercased()
            return lowered == "true" || lowered == "1" || lowered == "yes"
        }
        return false
    }

    /// 激活状态：Activated / Unactivated / Unactivated（无卡）之类，给中文
    static func activationText(_ raw: String) -> String {
        switch raw {
        case "": return ""
        case "Activated": return "已激活"
        case "Unactivated": return "未激活"
        default: return raw
        }
    }

    /// RegionInfo → 「中国（CH）」。
    /// 这个字典不同系统键名不一样：可能是 Country/RegionCode/Region，
    /// 也可能整个是空的 —— 那时就从型号号码推：`MQ0W3CH/A` 的 `CH` 就是销售地区。
    static func regionText(modelNumber: String,
                           regionInfo: [String: Any]?,
                           regionString: String? = nil) -> String {
        // 设备直接给 "CH/A" 这种字符串时，取斜杠前的两位
        if let raw = regionString?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let code = raw.split(separator: "/").first.map(String.init) ?? raw
            if code.count == 2, code.allSatisfy({ $0.isLetter }) {
                return "\(regionName(code))（\(code)）"
            }
        }
        if let info = regionInfo, !info.isEmpty {
            let country = (info["Country"] as? String) ?? ""
            let code = (info["RegionCode"] as? String)
                ?? (info["Region"] as? String)
                ?? (info["CountryCode"] as? String)
                ?? ""
            if !country.isEmpty, !code.isEmpty { return "\(country)（\(code)）" }
            if !code.isEmpty { return "\(regionName(code))（\(code)）" }
            if !country.isEmpty { return country }
            // 型号号码也在这个字典里时，往下走统一解析
            if let model = info["ModelNumber"] as? String, let text = regionFromModel(model) {
                return text
            }
        }
        return regionFromModel(modelNumber) ?? ""
    }

    /// 从型号号码尾巴取销售地区：`MQ0W3CH/A` → `CH` → 「中国大陆（CH）」
    static func regionFromModel(_ model: String) -> String? {
        let trimmed = model.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty else { return nil }
        // 形如 XXXXX<两位区域>/A
        guard let slash = trimmed.firstIndex(of: "/") else { return nil }
        let tail = trimmed[trimmed.index(slash, offsetBy: -2)..<slash]
        let code = String(tail)
        guard code.count == 2, code.allSatisfy({ $0.isLetter }) else { return nil }
        return "\(regionName(code))（\(code)）"
    }

    /// 常见销售地区码。认不出来的就只显示码，不编国家。
    static func regionName(_ code: String) -> String {
        switch code.uppercased() {
        case "CH": return "中国大陆"
        case "ZP", "XZ", "ZA", "HB": return "港澳台"
        case "LL": return "美国"
        case "J": return "日本"
        case "KH": return "韩国"
        case "TA": return "台湾"
        case "B", "GB": return "英国"
        case "D": return "德国"
        case "F": return "法国"
        case "IP": return "意大利"
        case "X", "XZ/A": return "澳大利亚"
        case "RU": return "俄罗斯"
        case "BR": return "巴西"
        case "AE": return "阿联酋"
        case "HN": return "印度"
        case "SO": return "南非"
        case "ZD": return "欧洲"
        case "PL", "PM": return "波兰"
        case "MY": return "马来西亚"
        case "TH": return "泰国"
        case "VN": return "越南"
        case "SG": return "新加坡"
        default: return code
        }
    }

    /// TimeZone 通常是 "Asia/Shanghai"，直接展示，把下划线还原成空格
    static func timeZoneText(_ raw: String) -> String {
        raw.isEmpty ? "" : raw.replacingOccurrences(of: "_", with: " ")
    }
}
