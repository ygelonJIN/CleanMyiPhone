import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppStore {

    // MARK: - 导航

    enum Section: String, Identifiable {
        case overview, photos, albums, trash
        var id: String { rawValue }
    }

    /// 侧边栏的一行。侧栏选中项就是唯一真相：section / 筛选都从这里推出来，
    /// 不会再出现「侧栏选中 A、内容显示 B」的错位。
    enum SidebarItem: Hashable {
        case overview
        case albums
        case photos(LibraryFilter)
        case album(Int)
        case trash
    }

    var sidebarItem: SidebarItem = .overview

    /// 换页动画的 key：换页 / 换相簿 / 切网格↔列表才变。
    /// **搜索和筛选故意不算**，否则每敲一个字整屏都重播一次淡入。
    var pageKey: String {
        switch sidebarItem {
        case .overview: return "overview"
        case .albums: return "albums"
        case .photos(let filter): return "photos.\(filter.id).\(viewMode)"
        case .album(let id): return "album.\(id).\(viewMode)"
        case .trash: return "trash.\(viewMode)"
        }
    }

    var section: Section {
        switch sidebarItem {
        case .overview: return .overview
        // 「相簿」和「某个相簿里」都算相簿这一节：二级栏（相簿列表）只在那一节出现
        case .albums, .album: return .albums
        case .photos: return .photos
        case .trash: return .trash
        }
    }

    var libraryFilter: LibraryFilter {
        if case .photos(let filter) = sidebarItem { return filter }
        return .all
    }

    var albumFilter: Int? {
        if case .album(let id) = sidebarItem { return id }
        return nil
    }


    func select(_ item: SidebarItem) {
        guard item != sidebarItem else { return }
        sidebarItem = item
        if case .albums = item { ensureAlbumSelection() }
        clearSelection()
        closePreview()
    }

    // MARK: - 状态

    var device: DeviceSnapshot?
    var assets: [Asset] = []
    var errorText: String?

    // 设备照片库
    var libraryIndex: PhotoLibraryIndex?
    var libraryAlbums: [PhotoLibraryIndex.Album] = []
    var libraryStatus: String?
    /// 连续失败次数：满 3 次就停掉自动重试，别一直撞同一面墙
    private(set) var libraryFailureCount = 0
    /// 自动重试已停（门禁要提示「点重新读取」）
    private(set) var libraryAutoRetryStopped = false
    /// 正在重试中（门禁显示「正在重试…」，但仍保留上次的失败原因）
    private(set) var libraryRetrying = false
    var screenImage: NSImage?
    var stats = LibraryService.DeviceStats()

    // 压缩 / 转换（批量）
    var conversionRunning = false
    var conversionProgress: PhotoConversionEngine.Progress?
    var conversionResult: PhotoConversionEngine.Result?

    var sortKey: SortKey = .date
    var dateGrouping: DateGrouping = .month
    var ascending = false
    var viewMode: ViewMode = .grid
    var searchText = ""
    var kindFilter: MediaKind?
    var tagFilter: MediaTag?
    var cloudOnlyFilter = false

    var selection: Set<Asset.ID> = []
    var anchorID: Asset.ID?
    /// 鼠标当前悬停的那一项：空格预览只认它
    var hoveredID: Asset.ID?

    let trash = TrashStore()
    /// 清空回收站 / 彻底删除中的二次确认弹窗
    var emptyTrashConfirmPresented = false
    /// 弹窗里要彻底删除的那一批（空 = 全部）
    var pendingDeleteIDs: [Asset.ID] = []
    var isPurging = false
    /// 删除中弹窗的数据源：非 nil 就盖一层「正在删除」（跟着设备回执一格格走）
    var purgeProgress: PurgeProgress?
    /// 删完的结果单：非 nil 就弹结果弹窗（成功几条、失败几条、每条为什么）
    var purgeReport: PurgeReport?
    var purgeMessage: String?
    /// 打完标记后底栏闪一句「已标记 N 项到回收站」，2.4 秒后自动消失
    var provisionalMessage: String?

    var columns = 6
    var previewID: Asset.ID?
    /// 正在播退出动画：预览层按它反向缩放，180 ms 后才真正拆除（不靠淡出糊过去）。
    var isClosingPreview = false
    /// 打开预览时那一格在 **root 坐标系**里的矩形：预览卡片从它的中心长出来。
    /// 用 `@ObservationIgnored`：格子悬停时写、预览层读一次，不该触发任何重绘。
    @ObservationIgnored var previewAnchorRect: CGRect?
    var previewImage: NSImage?
    /// 卡片第一行：固定文案，不随数字宽度变
    var previewLoadingHint: String {
        if !previewStageText.isEmpty { return previewStageText }
        if libraryIndex == nil, !usingFixture { return "正在读取相册索引" }
        return "正在取回视频"
    }

    /// 预览取回进度（字节），界面用它画确定性进度条
    private(set) var previewBytesDone: Int64 = 0
    private(set) var previewBytesTotal: Int64 = 0
    var previewBytesFraction: Double {
        guard previewBytesTotal > 0 else { return 0 }
        return min(1, Double(previewBytesDone) / Double(previewBytesTotal))
    }
    var previewVideoURL: URL?
    /// 实况照片的**视频分量**（同目录、同 basename 的 `.MOV`）。
    /// 真机实测：DCIM 下「图 + 同名视频」有 410 组，所以靠文件名就能配对，
    /// 不用去啃 `ZINTERNALRESOURCE`。取到就自动循环播放，取不到就停在静态图。
    var previewLiveVideoURL: URL?
    var previewLoading = false
    /// 卡片第二行：**只放数字**（x MB / y MB 或一句"重试中"），不再重复"正在取回视频"
    var previewProgressText = ""
    /// 卡片第一行：阶段说明
    private(set) var previewStageText = ""
    var previewError: String?
    var thumbnails: [Asset.ID: NSImage] = [:]
    /// 缩略图批次号：PTP 恢复后 +1，格子靠 `.task(id:)` 重新取一次
    var thumbEpoch = 0

    /// 没接上真机：停在「连接 iPhone」空状态，不再悄悄回落模拟设备
    var needsConnection = false
    /// 设备锁屏：直接给提示，不假装在读取
    var isDeviceLocked = false

    // 相册索引的字节进度（MB 级，按四个文件大小累加当分母）
    var libraryBytesDone: Int64 = 0
    var libraryBytesTotal: Int64 = 0

    /// 相册索引没就绪就**整窗盖死**，什么都点不了。
    ///
    /// 三条口径（2026-11 用户定的）：
    /// 1. **不分页面** —— 概览页也盖。以前只盖照片/相簿页，于是在概览上点「重新读取」
    ///    看到的是"界面先进去了"，用户原话：「不要先进去再读取」。
    /// 2. **不分锁屏** —— 锁屏时也盖着，写「设备已锁屏，解锁后自动继续读」；
    ///    解锁由 `unlockWatch` 每 2 秒探一次，解开就自动重读，不用用户回来点。
    /// 3. 暂停态（手动清空过）和未连接不盖：那两种要能点到「重新读取」/「重新检测」。
    var needsLibraryGate: Bool {
        guard libraryIndex == nil, !usingFixture else { return false }
        return !dataPaused && !needsConnection
    }

    /// 正在读相册索引（含手动重试）。门禁按它决定画「进度」还是「失败卡」——
    /// 点了「重新读取」之后必须**继续盖着显示在读**，不许闪回失败卡。
    var libraryReadingNow: Bool {
        libraryRetrying || (libraryStarted && !libraryDone)
    }

    // MARK: - 读取进度（全流程只有一个进度）

    /// 0–1，唯一进度。进度条、百分比、侧栏、概览都读这一个数，
    /// 不再有「照片目录 60% + 相簿 40%」两套数字互相打架。
    private(set) var progress: Double = 0
    private(set) var scanFinished = false
    private var catalogFraction: Double = 0
    private var libraryFraction: Double = 0
    private var catalogDone = false
    private var libraryStarted = false
    private var libraryDone = false
    /// 相册索引已经读过就只刷新目录，进度按目录这一段走满
    private var librarySkipped = false

    var isScanning: Bool { !scanFinished && !usingFixture }

    /// 相册库正在读哪个文件（子进程的 FILE 行）。
    /// 卡住时能看出卡在哪一个，而不是盯着一个不动的百分比。
    var libraryFileStage: String = ""

    var scanStageTitle: String {
        if needsConnection { return "未连接" }
        if isDeviceLocked { return "设备已锁屏" }
        if scanFinished { return "读取完成" }
        if libraryStarted && !libraryDone { return "正在读取相册索引" }
        if !catalogDone { return "正在读取照片目录" }
        if !scanFinished { return "正在读取设备信息" }
        return "读取完成"
    }

    /// 「132.4 MB / 296.5 MB」——分母是四个文件大小之和，只做展示不做收尾判断
    var libraryByteText: String? {
        guard libraryStarted, !libraryDone, libraryBytesTotal > 0 else { return nil }
        return "\(Self.sizeText(libraryBytesDone)) / \(Self.sizeText(libraryBytesTotal))"
    }

    /// 只报「在干什么 + 读了多少」，不报百分比：
    /// 百分比是按目录/库两段权重算的，和字节数不同步，卡住时它不动反而更可疑。
    var progressText: String {
        if let bytes = libraryByteText {
            let stage = libraryFileStage.isEmpty ? scanStageTitle : "正在读取 \(libraryFileStage)"
            return "\(stage) \(bytes)"
        }
        return scanStageTitle
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - 数据源

    private(set) var source: any DeviceSource
    private(set) var usingFixture: Bool
    @ObservationIgnored private lazy var ptp = PTPBridge()
    @ObservationIgnored private var ptpWired = false
    private var ptpAllowed: Bool { ProcessInfo.processInfo.environment["CMI_NO_IC"] == nil }
    @ObservationIgnored private var thumbTasks: [Asset.ID: Task<Void, Never>] = [:]
    private var sessionTask: Task<Void, Never>?
    private var libraryRetryTask: Task<Void, Never>?
    /// 扫描的最后一道时间闸（见 `scheduleScanDeadline`）
    private var scanDeadlineTask: Task<Void, Never>?
    private var didBootstrap = false

    init() {
        usingFixture = true
        source = FixtureDevice()
        device = .fixture
    }

    /// 只有真的要枚举照片时才建 ICCamera 设备浏览器
    private func startPTP() {
        guard ptpAllowed else { return }
        wirePTP()
        ptp.start()
    }

    private func stopPTP() {
        guard ptpWired else { return }
        ptp.stop()
    }

    private func wirePTP() {
        guard ptpAllowed, !ptpWired else { return }
        ptpWired = true
        ptp.onDevice = { [weak self] snapshot in
            guard let self, let snapshot else { return }
            self.device = snapshot
            if self.usingFixture {
                self.usingFixture = false
                self.source = self.ptp
                self.assets = []
                self.errorText = nil
                self.resetScan(skipLibrary: false)
            }
            self.beginSession()
        }
        ptp.onCatalog = { [weak self] list, fraction in
            guard let self, !self.usingFixture else { return }
            self.assets = list
            self.catalogFraction = fraction
            self.recomputeProgress()
            self.invalidateCounts()
            self.reconcileSelection()
            if ProcessInfo.processInfo.environment["CMI_AUTO_PREVIEW"] != nil,
               self.previewID == nil,
               let video = list.first(where: { $0.kind == .video }) {
                self.previewID = video.id
                self.loadPreviewImage(for: video.id)
            }
            Self.debugLog("catalog \(list.count) progress \(fraction)")
        }
        ptp.onCatalogFinished = { [weak self] in
            guard let self else { return }
            // 目录重来过一遍：让格子重新试一次缩略图
            self.thumbEpoch &+= 1
            self.catalogDone = true
            self.catalogFraction = 1
            self.recomputeProgress()
            self.maybeFinishScan()
            if self.libraryLooksStale() { self.scheduleLibraryRefresh() }
        }
        ptp.onError = { [weak self] message in
            self?.errorText = message
        }
    }

    // MARK: - 启动

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        Self.debugLog("[boot] start")
        resetScan(skipLibrary: false)
        applyDebugStartSection()
        // 启动第一件事：清掉上一次**非正常退出**（崩溃 / kill -9 / 断电）留下的痕迹。
        // 正常退出时上一轮已经在 `applicationWillTerminate` 里清干净了，这里什么都不用删，
        // 所以这一步不会白删东西 —— 它是"再怎么退出也不留痕"的最后一道兜底
        // （SIGKILL 那种进程没有执行机会的情况，靠的就是下一次启动的这一行）。
        // **无条件**清一次，不看任何开关：
        // 上一次是崩溃 / kill -9 / 断电的话，进程没机会自己收尾，只能靠这一行。
        // 正常退出时上一轮已经清干净了，这里什么都不会删。
        let leftovers = Self.purgeLocalDataOnDisk()
        if !leftovers.isEmpty {
            Self.debugLog("[purge] 启动清理上次非正常退出的残留：\(leftovers.joined(separator: "、"))")
        }
        purgeLeftovers = leftovers

        // 模拟设备只留给开发：CMI_FIXTURE=1 才用
        guard ProcessInfo.processInfo.environment["CMI_FIXTURE"] == nil, ptpAllowed else {
            enterFixture()
            return
        }

        // 默认就是真机。没插就停在「连接 iPhone」页，不再悄悄换成模拟设备。
        usingFixture = false
        source = ptp
        needsConnection = false
        guard LibraryService.isDeviceAvailable() else {
            stopPTP()
            needsConnection = true
            scanFinished = true
            return
        }

        // 1) 先读相册库：这时还没有 ICCamera 会话，AFC 能独占设备。
        //    反过来（PTP 先起）会让子进程的 AFC 打不开文件。
        await loadLibrary()

        // 2) 再启动 PTP 枚举照片
        startPTP()
        let deadline = Date().addingTimeInterval(10)
        while !catalogDone && Date() < deadline {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        if catalogDone || !assets.isEmpty {
            maybeFinishScan()
            return
        }

        // PTP 没上来：锁屏就直接说锁屏，否则提示读不到照片目录
        if libraryDone || librarySkipped {
            catalogDone = true
            if errorText == nil, !isDeviceLocked {
                errorText = "读不到照片目录，解锁 iPhone 后再刷新"
            }
            maybeFinishScan()
        }
    }

    /// 调试用：CMI_START_SECTION=apps|files|photos|trash 直接落到某一页，方便截图核对
    private func applyDebugStartSection() {
        // 命令行也认：`open build/cleanmyiphone.app --args --albums`（零痕迹测试/截图用）
        if CommandLine.arguments.contains("--albums") { sidebarItem = .albums; return }
        guard let raw = ProcessInfo.processInfo.environment["CMI_START_SECTION"]?.lowercased() else { return }
        switch raw {
        case "trash": sidebarItem = .trash
        case "photos": sidebarItem = .photos(.all)
        case "albums": sidebarItem = .albums
        // 影子资产（已隐藏 / 最近删除）排查用：这两个筛选的数据来自库而不是 PTP
        case "hidden": sidebarItem = .photos(.hidden)
        case "trashed": sidebarItem = .photos(.trashed)
        default: sidebarItem = .overview
        }
    }

    /// 开发用模拟数据（不接手机也能看界面）
    private func enterFixture() {
        stopPTP()
        usingFixture = true
        needsConnection = false
        isDeviceLocked = false
        source = FixtureDevice()
        device = .fixture
        assets = []
        invalidateCounts()
        applyFixtureStats()
        catalogDone = true
        catalogFraction = 1
        finishScan()
        Task { [weak self] in
            guard let self else { return }
            self.assets = (try? await (self.source as? FixtureDevice)?.load()) ?? []
            self.invalidateCounts()
            self.finishScan()
            self.runPurgeDemoIfRequested()
        }
    }

    /// 只给模拟设备用的界面回归入口：`CMI_PURGE_DEMO=<条数>` 启动，
    /// 自动把前 N 项标进回收站并点一次「彻底删除」，用来截图看
    /// 「正在删除」和结果单（真机路径不会走到这里）。
    private func runPurgeDemoIfRequested() {
        guard usingFixture,
              let raw = ProcessInfo.processInfo.environment["CMI_PURGE_DEMO"],
              let count = Int(raw), count > 0 else { return }
        let chosen = Array(assets.prefix(count))
        guard !chosen.isEmpty else { return }
        trash.add(chosen, deviceID: device?.id ?? "fixture")
        sidebarItem = .trash
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self else { return }
            await self.deleteFromTrash(ids: chosen.map(\.id))
        }
    }

    func connectRealDevice() {
        usingFixture = false
        source = ptp
        assets = []
        thumbnails = [:]
        clearSelection()
        needsConnection = false
        isDeviceLocked = false
        libraryDone = false
        libraryStarted = false
        librarySkipped = false
        device = DeviceSnapshot(id: "connecting", name: "iPhone", model: "正在读取", isReady: false)
        resetScan(skipLibrary: false)
        scheduleScanDeadline()
        Task { await bootstrapAfterRetry() }
    }

    /// 用户点「连接真机」/「重试」时重走一遍真机流程
    private func bootstrapAfterRetry() async {
        guard LibraryService.isDeviceAvailable() else {
            needsConnection = true
            scanFinished = true
            return
        }
        await loadLibrary()
        startPTP()
        let deadline = Date().addingTimeInterval(10)
        while !catalogDone && Date() < deadline {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        if catalogDone || !assets.isEmpty { maybeFinishScan() }
    }

    func useFixture() {
        guard !usingFixture else { return }
        sessionTask?.cancel()
        stopPTP()
        usingFixture = true
        libraryDone = false
        libraryStarted = false
        librarySkipped = false
        source = FixtureDevice()
        device = .fixture
        assets = []
        thumbnails = [:]
        clearSelection()
        Task {
            assets = (try? await (source as? FixtureDevice)?.load()) ?? []
            invalidateCounts()
            applyFixtureStats()
            finishScan()
        }
    }

    /// 模拟设备也给一套容量，界面能完整预览（不接手机也能看环形与卡片）
    private func applyFixtureStats() {
        var fake = LibraryService.DeviceStats()
        fake.totalCapacity = 256_000_000_000
        fake.available = 84_000_000_000
        fake.deviceName = "iPhone（模拟）"
        fake.productType = "iPhone15,2"
        fake.productVersion = "26.7"
        fake.serial = "FIXTURE0000"
        fake.batteryLevel = 86
        fake.modelNumber = "MQ0W3"
        fake.buildVersion = "23A341"
        fake.activationState = "已激活"
        fake.cpuArchitecture = "arm64e"
        fake.region = "中国（CH）"
        fake.timeZone = "Asia/Shanghai"
        fake.isPaired = true
        fake.deviceLocked = false
        fake.batteryCharging = true
        fake.externalConnected = true
        fake.fullyCharged = false
        fake.lowPowerMode = false
        fake.batteryDesign = 3181
        fake.batteryHealthPercent = 100
        fake.batteryRawMax = 3181
        fake.batteryCycles = 1516
        fake.carrier = "中国电信"
        stats = fake
    }

    /// 用户主动「刷新」：暂停态下先解除暂停，再读。
    /// 菜单 ⌘R、照片页工具栏、锁屏解锁后的自动重读都走这一个入口，
    /// 谁都不许绕过 `dataPaused` 自己重新读库。
    func refreshDevice() async {
        if dataPaused {
            resumeReading()
            return
        }
        await startScan()
    }

    /// 批量压缩/转换：先把 App 自己的两条 AFC 让开，再让引擎独占一条连接。
    /// 引擎会在改库前重新抓一份当前库，所以批次跑得久也不会丢新照片。
    func startConversion(items: [ConversionItem], profile: ConversionProfile) {
        guard !conversionRunning, !items.isEmpty else { return }
        conversionRunning = true
        conversionResult = nil
        conversionProgress = PhotoConversionEngine.Progress(
            phase: "准备", completed: 0, total: items.count, current: "")

        let udid = stats.udid
        let workDir = URL(fileURLWithPath: "/tmp/cmi-convert-\(UUID().uuidString)",
                          isDirectory: true)

        Task {
            await releaseDeviceFiles()
            stopPTP()
            do {
                let engine = try PhotoConversionEngine(udid: udid, workDir: workDir)
                let result = await Task.detached { [weak self] in
                    engine.run(items: items, profile: profile) { progress in
                        Task { @MainActor in
                            self?.conversionProgress = progress
                        }
                    }
                }.value
                conversionResult = result
                conversionRunning = false
                await refreshDevice()
                markConvertedOriginals(result)
            } catch {
                var result = PhotoConversionEngine.Result()
                result.failures = [("转换", error.localizedDescription)]
                conversionResult = result
                conversionRunning = false
                await refreshDevice()
            }
        }
    }

    /// 转换成功后，把原图按现有「标记回收」流程放进回收站（橙色），
    /// 用户到回收站点「彻底删除」才真正从手机删。
    private func markConvertedOriginals(_ result: PhotoConversionEngine.Result) {
        guard !result.records.isEmpty else { return }
        let pks = Set(result.records.map(\.originalPK))
        let originals = visibleAssets.filter { asset in
            guard let meta = meta(asset) else { return false }
            return pks.contains(meta.pk)
        }
        guard !originals.isEmpty else { return }
        trash.add(originals, deviceID: device?.id ?? "unknown")
        clearSelection()
        flash("已压缩 \(result.records.count) 张，原图已标记到回收站")
    }

    func startScan() async {
        // 手动清空过 = 暂停态：不重扫、不重读、不重建缩略图。
        // 想恢复只能点「重新读取」（或走 `refreshDevice`，它先解除暂停）。
        guard !dataPaused else { return }
        if usingFixture {
            assets = (try? await (source as? FixtureDevice)?.load()) ?? []
            invalidateCounts()
            applyFixtureStats()
            finishScan()
            return
        }
        errorText = nil
        isDeviceLocked = false
        if !LibraryService.isDeviceAvailable() {
            needsConnection = true
            scanFinished = true
            return
        }
        needsConnection = false
        // 刷新 = 重新读一遍设备。以前这里是 `resetScan(skipLibrary: libraryDone)`：
        // 库已经读过就整段跳过，只重枚举一遍 /DCIM，缩略图还在内存里，
        // 界面上什么都不变 —— 用户点了等于没点（连"清空"按钮都会先闪掉一下）。
        resetScan(skipLibrary: false)
        libraryStatus = nil
        stopPTP()
        startPTP()
        // 以前这里只靠 PTP 的 `onDevice` 回调去触发 `beginSession()`（那条链才会读库）。
        // 会话没真正重开时（解锁后刷新最典型：ICCamera 还挂着同一个设备，不会再报一次
        // device）回调不会来 → 库永远不重读，界面停成
        // 「正在读取相册索引 / 正在等手机回包 / 已读 0 KB」一直不动。
        // 这里直接起一次会话链，不依赖回调是否还会来。
        beginSession()
        scheduleScanDeadline()
    }

    /// 扫描的**最后一道时间闸**：超时就收尾，绝不让界面永远转圈。
    ///
    /// 为什么必须有：`isScanning` 只认 `scanFinished`，而 `maybeFinishScan()` 要求
    /// `catalogDone`。PTP 会话被设备侧关掉时（iPhone 锁屏最常见），目录枚举永远不会
    /// 完成 → 界面永远显示「正在读取照片目录」、刷新按钮永远是转圈禁用态、
    /// 删除整批报「设备未连接」，用户被彻底锁死，连重试的按钮都点不了
    /// （2026-11-01 用户现场踩到）。`bootstrapAfterRetry` 里那段 10 秒兜底只覆盖
    /// 首启，⌘R / 刷新按钮走的 `startScan` 这条路上原来一个兜底都没有。
    private func scheduleScanDeadline(timeout: TimeInterval = 30) {
        scanDeadlineTask?.cancel()
        scanDeadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.scanFinished else { return }
            if !self.catalogDone {
                self.catalogDone = true
                self.catalogFraction = 1
                if self.errorText == nil, !self.isDeviceLocked {
                    self.errorText = "读不到照片目录：解锁 iPhone 后点刷新重试"
                }
            }
            self.recomputeProgress()
            self.maybeFinishScan()
            self.finishScan()
            Self.debugLog("scan deadline fired：强制收尾（catalogDone forced）")
        }
    }

    private func beginSession() {
        // 闸门从这里开始计时最准：会话真正开始的那一刻。上面 startScan / 连接真机
        // 那两处也各挂了一次（不依赖 `onDevice` 回调是否还会来），这里是幂等覆盖。
        scheduleScanDeadline()
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            guard let self else { return }
            await self.waitForCatalog(timeout: 25)
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self.loadLibrary()
            guard !Task.isCancelled else { return }
            // 索引正在下载时不打断它，等它下完再收尾
            if self.libraryStarted && !self.libraryDone {
                await self.waitForLibrary(timeout: 180)
            }
            self.maybeFinishScan()
        }
    }

    private func waitForCatalog(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !catalogDone && Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    private func waitForLibrary(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !libraryDone && Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    private func resetScan(skipLibrary: Bool) {
        progress = 0
        scanFinished = false
        catalogFraction = 0
        libraryFraction = 0
        catalogDone = false
        libraryBytesDone = 0
        libraryBytesTotal = 0
        librarySkipped = skipLibrary
        if !skipLibrary {
            libraryStarted = false
            libraryDone = false
        }
    }

    private func finishScan() {
        guard !scanFinished else { return }
        scanFinished = true
        scanDeadlineTask?.cancel()          // 已经收尾，闸门不必再睡到点
        scanDeadlineTask = nil
        progress = 1
        Self.debugLog("scan finished")
    }

    /// 目录与相册都到位就收尾（不依赖任务链，避免一直显示「正在读取」）
    private func maybeFinishScan() {
        guard !usingFixture, !scanFinished else { return }
        guard catalogDone, libraryDone || librarySkipped else { return }
        finishScan()
    }

    /// 只进不退；完整流程：连接 0.06 → 照片目录 0.30 → 相册索引 0.92 → 设备信息 1.0
    private func recomputeProgress() {
        guard !scanFinished else { progress = 1; return }
        let catalogEnd = librarySkipped ? 0.92 : 0.30
        let catalogValue = catalogDone ? 1.0 : min(max(catalogFraction, 0), 1)
        var target = 0.06 + catalogValue * (catalogEnd - 0.06)

        if !librarySkipped, libraryStarted || libraryDone {
            let libraryValue = libraryDone ? 1.0 : min(max(libraryFraction, 0), 1)
            target = max(target, 0.30 + libraryValue * 0.62)
        }
        if catalogDone && (libraryDone || librarySkipped) {
            target = max(target, 0.96)
        }
        let clamped = min(max(target, 0), 1)
        if clamped > progress { progress = clamped }
    }

    private static func debugLog(_ line: String) {
        guard ProcessInfo.processInfo.environment["CMI_DEBUG"] != nil else { return }
        let url = URL(fileURLWithPath: "/tmp/cmi-app.log")
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    private func reconcileSelection() {
        let living = Set(assets.map(\.id))
        selection.formIntersection(living)
        if let anchorID, !living.contains(anchorID) { self.anchorID = nil }
        if let hoveredID, !living.contains(hoveredID) { self.hoveredID = nil }
    }

    // MARK: - 设备照片库


    func loadLibrary() async {
        if ProcessInfo.processInfo.environment["CMI_NO_LIBRARY"] != nil {
            libraryStarted = true
            libraryDone = true
            libraryFraction = 1
            recomputeProgress()
            return
        }
        guard !usingFixture, !libraryDone, !libraryStarted else { return }
        libraryStarted = true
        recomputeProgress()

        // 看门狗：相册库万一卡住，超时也要收尾，界面不能永远停在「正在读取」
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000_000)
            guard let self, !self.libraryDone else { return }
            self.libraryDone = true
            self.libraryFraction = 1
            self.rebuildMetrics()
            if self.libraryStatus == nil {
                self.libraryStatus = "读取相册索引超时，点刷新重试"
            }
            self.recomputeProgress()
            self.maybeFinishScan()
        }

        do {
            let snapshot = try await LibraryService.fetch(progress: { [weak self] value in
                guard let self else { return }
                self.libraryFraction = value
                self.recomputeProgress()
            }, onBytes: { [weak self] done, total in
                guard let self else { return }
                self.libraryBytesDone = done
                // 分母只认第一次：WAL 大小随时在变，跟着变会让进度倒退
                if self.libraryBytesTotal == 0 { self.libraryBytesTotal = total }
            }, onFile: { [weak self] name in
                self?.libraryFileStage = name
            })
            libraryIndex = snapshot.index
            metaCacheStore.removeAll()
            Self.debugLog("[library] 从设备读完整库，库索引就绪（门禁撤）")
            libraryAlbums = snapshot.index.albumsSorted()
            ensureAlbumSelection()
            invalidateCounts()
            applyStats(snapshot.stats)
            libraryDone = true
            libraryFraction = 1
            libraryStatus = nil
            isDeviceLocked = false
            recomputeProgress()
            maybeFinishScan()
            await refreshScreen()
        } catch {
            Self.debugLog("[library] 读取失败：\(error.localizedDescription)")
            // 失败也不留半份落盘：四件套只作中转，绝不留在硬盘上
            LibraryService.purgeSnapshotFiles()
            libraryDone = true
            libraryFraction = 1
            rebuildMetrics()
            libraryStatus = error.localizedDescription
            libraryFailureCount += 1
            if let service = error as? LibraryService.ServiceError, case .locked = service {
                isDeviceLocked = true
                // 锁屏时什么都读不到。开一个探针盯着，一解锁就自动重读，
                // 不用让用户自己回来点刷新（之前解锁了界面还停在"设备已锁屏"）。
                startUnlockWatch()
                recomputeProgress()
                maybeFinishScan()
                return
            }
            // 相册库读不到也要拿到容量/型号，概览才有内容。
            // 走带超时的离线版本：设备管子坏的时候 @MainActor 那版会把界面冻住。
            if stats.totalCapacity == 0, let fallback = await LibraryService.deviceStatsOffMain() {
                applyStats(fallback)
            }
            recomputeProgress()
            maybeFinishScan()
            scheduleLibraryRetry()
        }
    }

    @ObservationIgnored private var unlockWatch: Task<Void, Never>?

    /// 锁屏时每 2 秒问一次设备解锁了没有，解锁就自动重新读
    private func startUnlockWatch() {
        guard unlockWatch == nil else { return }
        unlockWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                // 手动清空之后是暂停态：解锁**不该**偷偷把 296 MB 又读回来
                guard !self.dataPaused else { return }
                let unlocked = await Task.detached { !LibraryService.isDeviceLocked() }.value
                guard unlocked else { continue }
                await MainActor.run {
                    self.isDeviceLocked = false
                    self.unlockWatch = nil
                }
                guard !self.dataPaused else { return }
                await self.refreshDevice()
                return
            }
        }
    }

    /// 设备上出现了比本地快照更新的照片 → 相册库快照过期
    ///
    /// 判据就是「**设备上最新那张资产的时间，比快照里最新那张新 2 分钟以上**」。
    /// 你刚拍两张照片 → 它们的时间戳一定比快照里最新那张新 → 判为过期 → 本次运行重抓一次。
    /// （所以"6 小时内识别不出来"是**不会**发生的：快照只是缺条目，PTP 枚举永远是最新的，
    /// 一拍到就会被看见，重抓只是把索引补齐。真正会慢的只有那一次 296 MB 重读。）
    ///
    /// 每次运行最多重抓一次（`didAutoRefreshLibrary`）：避免"设备一直在拍 → 一直重抓"。
    /// 原来的 120 秒判据之所以是灾难，是因为**残缺快照**会让它永远为真；
    /// 那个根因现在由 `ServiceError.incomplete` 的完整性对账堵住了，所以这里可以恢复成灵敏判据。
    private func libraryLooksStale() -> Bool {
        guard let index = libraryIndex, !index.isEmpty, !usingFixture else { return false }
        guard let newestDevice = assets.map(\.createdAt).max() else { return false }
        let newestSnapshot = index.metaByFile.values.map(\.createdAt).max() ?? .distantPast
        return newestDevice.timeIntervalSince(newestSnapshot) > 120
    }

    @ObservationIgnored private var didAutoRefreshLibrary = false

    /// 快照过期时后台悄悄重抓一次（会短暂让出设备，抓完恢复 PTP）
    private func scheduleLibraryRefresh() {
        guard !didAutoRefreshLibrary, !usingFixture, libraryIndex != nil else { return }
        didAutoRefreshLibrary = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.libraryIndex != nil else { return }
            Self.debugLog("library snapshot stale, refreshing")
            await self.retryLibraryOnce(force: true)
        }
    }

    /// 相册库被 iOS 写库打断时，隔一段时间自动再试几次（不打扰用户）
    private func scheduleLibraryRetry() {
        guard !usingFixture, libraryIndex == nil else { return }
        // 连着失败三次就别再自动试了：通道坏了的时候每次重试都要起一个子进程去
        // 撞同一面墙（15 秒 + 一次 AFC 连接），越试越糟，界面还会一直在「正在读取」。
        guard libraryFailureCount < 3 else {
            libraryAutoRetryStopped = true
            Self.debugLog("[library] 已连续失败 \(libraryFailureCount) 次，停止自动重试")
            return
        }
        libraryRetryTask?.cancel()
        libraryRetryTask = Task { [weak self] in
            let waits: [UInt64] = [15, 30, 60, 120, 180]
            for seconds in waits {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.libraryIndex != nil { return }
                await self.retryLibraryOnce()
                if self.libraryIndex != nil { return }
            }
        }
    }

    /// 门禁里的「重新读取」：绕过 started/done 标记，重新读一次库。
    ///
    /// 点下去就把 `isDeviceLocked` 清掉：用户既然点了，就当他已经解锁。
    /// 还锁着的话 `loadLibrary` 会再失败并重新置 true，界面上表现为
    /// 「门禁一直盖着、又变回锁屏提示」，而不是先掉回正常界面
    /// —— 用户报的「点了重新读取，样式就变了（进去了）」就是这里漏的这一步。
    func retryLibraryNow() async {
        libraryFailureCount = 0
        libraryAutoRetryStopped = false
        isDeviceLocked = false
        await retryLibraryOnce(force: true)
    }

    private func retryLibraryOnce(force: Bool = false) async {
        guard !usingFixture else { return }
        if !force, libraryIndex != nil { return }
        // 重试前先把上一轮残留的辅助进程清掉：它们不随父进程退出，
        // 几个叠在一起就会互相抢设备，读库永远起不来。
        LibraryService.killStrayHelpers()
        // 重试时临时让出设备：有 ICCamera 会话时子进程的 AFC 会打不开文件
        let pausePTP = ptpWired
        if pausePTP { stopPTP() }
        // 也让出**自己的 AFC**：缩略图和预览各自攥着一条连接（`photoSession` /
        // `previewSession`）。重抓 296 MB 时它们还开着，就是「App 两条 + helper 一条」
        // 压在同一根管子上 —— 这是最容易把设备侧 afcd 顶到拒连的一档。
        await releaseDeviceFiles()
        try? await Task.sleep(nanoseconds: 800_000_000)

        // 从**按下那一刻**就算「在读」：让出设备 + 800 ms 静默这段也算，
        // 否则门禁会在这半秒里画成「失败卡」，看着像又没读成。
        libraryRetrying = true
        defer { libraryRetrying = false }

        libraryStarted = false
        libraryDone = false
        libraryFraction = 0
        // 注意：**不清 libraryStatus**。清了失败原因就没了；门禁按
        // `libraryReadingNow` 决定画进度、把原因留成底下那行小字。
        await loadLibrary()

        if pausePTP { startPTP() }
        maybeFinishScan()
    }

    /// 关掉 App 自己那两条 AFC 连接（读库前必须让开），不阻塞主线程：
    /// `reset()` 里是 `queue.sync`，正在下载缩略图时会等上几秒。
    private func releaseDeviceFiles() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                DeviceFiles.shared.cancelPending()
                DeviceFiles.shared.reset()
                continuation.resume()
            }
        }
    }

    private func applyStats(_ snapshot: LibraryService.DeviceStats) {
        stats = snapshot
        Self.debugLog("stats cap=\(snapshot.totalCapacity) free=\(snapshot.available) model=\(snapshot.productType)")
        let friendly = Self.friendlyModel(snapshot.productType)
        if !snapshot.deviceName.isEmpty || !friendly.isEmpty {
            let version = snapshot.productVersion.isEmpty ? "" : " · iOS \(snapshot.productVersion)"
            device = DeviceSnapshot(id: device?.id ?? "device",
                                    name: snapshot.deviceName.isEmpty ? (device?.name ?? "iPhone") : snapshot.deviceName,
                                    model: "\(friendly)\(version)",
                                    isReady: true)
        }
    }

    static func friendlyModel(_ productType: String) -> String {
        switch productType {
        case "iPhone15,2": return "iPhone 14 Pro"
        case "iPhone15,3": return "iPhone 14 Pro Max"
        case "iPhone16,1": return "iPhone 15 Pro"
        case "iPhone16,2": return "iPhone 15 Pro Max"
        case "iPhone17,1": return "iPhone 16 Pro"
        case "iPhone17,2": return "iPhone 16 Pro Max"
        case "": return ""
        default: return productType
        }
    }

    /// 抓一张设备当前画面（失败就算了，不影响主流程）
    func refreshScreen() async {
        guard !usingFixture else { return }
        do {
            let api = try MobileDeviceAPI.shared()
            let device = try api.firstDevice(timeout: 8)
            try api.openSession(device)
            defer { api.stopSession(device) }
            if let data = try api.screenshot(device), let image = NSImage(data: data) {
                screenImage = image
            }
        } catch {
            // 设备锁屏时截图服务不可用，静默跳过
        }
    }

    // MARK: - 统计

    var photoBytes: Int64 { assets.filter { $0.kind == .photo }.reduce(0) { $0 + $1.byteSize } }
    var videoBytes: Int64 { assets.filter { $0.kind == .video }.reduce(0) { $0 + $1.byteSize } }

    /// 照片/视频的**库口径**准备好了没有。
    /// 没准备好就别出数字：`数学上算得出来`不等于`数字是对的` —— 没有库时
    /// 「应用与数据」是拿「已用 − 媒体 − 系统 − 回收站」反推的，媒体按 PTP 的部分
    /// 资产算，视频一小、应用与数据就虚高一大截，看着就是「数据都不对」。
    var mediaBytesReady: Bool {
        guard let index = libraryIndex else { return false }
        return !index.isEmpty
    }

    /// 照片 / 视频体积以相册库里的 ZORIGINALFILESIZE 为准。
    /// PTP 报的 fileSize 普遍偏小（视频尤其离谱），不能用它做统计。
    var mediaPhotoBytes: Int64 {
        guard let index = libraryIndex, !index.isEmpty else { return photoBytes }
        return index.metaByFile.values.reduce(Int64(0)) { $0 + ($1.isVideo ? 0 : $1.resourceBytes) }
    }

    var mediaVideoBytes: Int64 {
        guard let index = libraryIndex, !index.isEmpty else { return videoBytes }
        return index.metaByFile.values.reduce(Int64(0)) { $0 + ($1.isVideo ? $1.resourceBytes : 0) }
    }

    var mediaTotalBytes: Int64 { mediaPhotoBytes + mediaVideoBytes }

    // MARK: - 侧栏指标：一次算完，视图只读这一份

    struct FilterMetric: Hashable {
        var count: Int
        var bytes: Int64
    }

    /// 侧栏每一行要显示的「数量 · 体积」。
    ///
    /// 以前是每行各自惰性算 + 各自缓存，而缓存是 `@ObservationIgnored`：
    /// 视图读缓存命中后就不再碰 `libraryIndex`，依赖断了，库到了也不刷新，
    /// 于是永远停在第一次算出来的 0，直到手动点一下别的东西才「跳出来」。
    /// 现在一整包赋值，视图读的就是可观察属性本身，库一到同一帧全部换掉。
    private(set) var filterMetrics: [LibraryFilter: FilterMetric] = [:]
    /// 数字算出来了没有（false → 界面统一显示「加载中」）
    private(set) var metricsReady = false
    /// 相册库确定读不到（锁屏 / 超时 / 格式不认）：这几行只能显示「—」
    private(set) var metricsLibraryUnavailable = false

    func rebuildMetrics() {
        guard let index = libraryIndex, !index.isEmpty else {
            filterMetrics = [:]
            metricsReady = false
            metricsLibraryUnavailable = libraryDone
            return
        }
        var photos = FilterMetric(count: 0, bytes: 0)
        var videos = FilterMetric(count: 0, bytes: 0)
        var favorites = FilterMetric(count: 0, bytes: 0)
        var hidden = FilterMetric(count: 0, bytes: 0)
        var trashed = FilterMetric(count: 0, bytes: 0)
        var shots = FilterMetric(count: 0, bytes: 0)
        var camera = FilterMetric(count: 0, bytes: 0)
        var live = FilterMetric(count: 0, bytes: 0)
        var raw = FilterMetric(count: 0, bytes: 0)
        let rows = index.allMeta.isEmpty ? Array(index.metaByFile.values) : index.allMeta
        for meta in rows {
            let bytes = meta.resourceBytes
            if meta.isVideo { videos.count += 1; videos.bytes += bytes }
            else { photos.count += 1; photos.bytes += bytes }
            if meta.isFavorite { favorites.count += 1; favorites.bytes += bytes }
            if meta.isHidden { hidden.count += 1; hidden.bytes += bytes }
            if meta.isTrashed { trashed.count += 1; trashed.bytes += bytes }
            if meta.subtype == 10 { shots.count += 1; shots.bytes += bytes }
            if meta.isCameraCaptured { camera.count += 1; camera.bytes += bytes }
            if meta.isLive { live.count += 1; live.bytes += bytes }
            if meta.isRaw { raw.count += 1; raw.bytes += bytes }
        }
        let all = FilterMetric(count: photos.count + videos.count, bytes: photos.bytes + videos.bytes)
        filterMetrics = [.all: all, .camera: camera, .photos: photos, .videos: videos,
                         .favorites: favorites, .screenshots: shots, .live: live,
                         .raw: raw, .hidden: hidden, .trashed: trashed]
        metricsReady = true
        metricsLibraryUnavailable = false
    }


    /// 相簿页：进来先落在一个相簿上，右边不至于空着。
    /// 库还没读到时先不动，等 `loadLibrary` 末尾再调一次。
    func ensureAlbumSelection() {
        guard section == .albums, albumFilter == nil,
              let first = libraryAlbums.max(by: { $0.count < $1.count }) else { return }
        sidebarItem = .album(first.id)
    }

    /// 相册库里的张数（含已隐藏 / 最近删除），PTP 没枚举出来时用它兜底
    var libraryPhotoCount: Int {
        guard let index = libraryIndex, !index.isEmpty else {
            return assets.filter { $0.kind == .photo }.count
        }
        return index.metaByFile.values.reduce(0) { $0 + ($1.isVideo ? 0 : 1) }
    }

    var libraryVideoCount: Int {
        guard let index = libraryIndex, !index.isEmpty else {
            return assets.filter { $0.kind == .video }.count
        }
        return index.metaByFile.values.reduce(0) { $0 + ($1.isVideo ? 1 : 0) }
    }
    var totalBytes: Int64 { assets.reduce(0) { $0 + $1.byteSize } }

    /// 真实容量拿到了没有（没拿到之前不显示任何数字）
    var hasStats: Bool { stats.totalCapacity > 0 }

    var usedPercent: Int {
        guard hasStats, deviceCapacity > 0 else { return 0 }
        let used = totalBytes + otherBytes + trash.totalBytes
        return min(100, max(0, Int(Double(used) / Double(deviceCapacity) * 100)))
    }

    var deviceCapacity: Int64 { stats.totalCapacity }
    var appBytes: Int64 { stats.appBytes }

    /// 已用 = 总容量 − 可用（和系统报的一致，不自己拼）
    var usedBytes: Int64 {
        guard hasStats else { return 0 }
        return max(0, deviceCapacity - stats.available)
    }

    var freeBytes: Int64 { hasStats ? stats.available : 0 }

    /// iOS 本体：系统分区容量 − 系统分区可用（实测 7.93 GB）
    var systemBytes: Int64 { max(0, stats.systemCapacity - stats.systemAvailable) }

    /// 除媒体、系统分区、回收站之外的残留：App 本体 + 文稿与数据 + 系统缓存
    var otherBytes: Int64 {
        guard hasStats else { return 0 }
        let rest = usedBytes - mediaTotalBytes - systemBytes - trash.totalBytes
        return max(0, rest)
    }

    /// 概览里「应用」那一格：就是 otherBytes（iOS 不给分项，不再二次扣减）
    var appsBytes: Int64 { otherBytes }

    /// 用户应用个数（系统 / 隐藏项不算）
    var userAppCount: Int { stats.appList.filter { !$0.isSystem }.count }

    struct Slice: Identifiable {
        let id = UUID()
        let title: String
        let bytes: Int64
        let color: Color
    }






    /// 相簿体积（按体积降序，只留 >0 的）
    

    /// 单个相簿的体积（带缓存，相簿栏和概览都要用）
    @ObservationIgnored private var albumByteCache: [Int: Int64] = [:]

    func albumBytes(_ albumID: Int) -> Int64 {
        if let cached = albumByteCache[albumID] { return cached }
        guard let index = libraryIndex else { return 0 }
        let files = index.files(inAlbum: albumID)
        var total: Int64 = 0
        if !files.isEmpty {
            // 按库里的成员求和：只数 PTP 枚举到的那部分会少一大截
            // （实测「微信」613 张，PTP 只覆盖 375 张 → 387 MB vs 真实 887 MB）
            for name in files {
                if let m = index.meta(for: name) { total += m.resourceBytes }
            }
            // 库里没有 meta 的（极少）再用 PTP 大小补
            if total == 0 {
                for asset in assets where files.contains(PhotoLibraryIndex.normalize(asset.fileName)) {
                    total += asset.byteSize
                }
            }
        }
        albumByteCache[albumID] = total
        return total
    }

    /// 类型排行（体积降序）：概览「照片类型」用它，和侧栏那套分类完全一致
    /// （相机 / 照片 / 视频 / 收藏 / 截图 / 实况 / RAW / 已隐藏 / 最近删除）。
    /// 「全部照片」不算类型，不进排行。
    var typeRanking: [(filter: LibraryFilter, count: Int, bytes: Int64)] {
        guard metricsReady else { return [] }
        return LibraryFilter.displayOrder
            .filter { $0 != .all }
            .compactMap { filter -> (LibraryFilter, Int, Int64)? in
                guard let metric = filterMetrics[filter],
                      metric.count > 0, metric.bytes > 0 else { return nil }
                return (filter, metric.count, metric.bytes)
            }
            .sorted { $0.2 > $1.2 }
    }

    /// 相簿排行（体积降序，含张数）：概览和相簿栏共用
    var albumRanking: [(album: PhotoLibraryIndex.Album, bytes: Int64)] {
        libraryAlbums
            .map { ($0, albumBytes($0.id)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }

    /// meta 查询带一层小缓存：饼图一次要跑好几遍，别每次都在字典里重新匹配
    @ObservationIgnored private var metaCacheStore: [Asset.ID: PhotoLibraryIndex.Meta?] = [:]

    func metaCache(_ asset: Asset) -> PhotoLibraryIndex.Meta? { meta(asset) }

    // MARK: - 筛选

    /// 单张资产的真实占用：优先用相册库里的资源合计，退回归一化后的 PTP 大小
    func byteSize(of asset: Asset) -> Int64 {
        if let meta = meta(asset), meta.resourceBytes > 0 { return meta.resourceBytes }
        return asset.byteSize
    }

    func meta(_ asset: Asset) -> PhotoLibraryIndex.Meta? {
        // 带缓存：`tagSet` / `computeVisible` / 侧栏统计会对着每张资产反复问，
        // 5000 张就是上万次查询，缓存命中后只剩一次字典读
        if let cached = metaCacheStore[asset.id] { return cached }
        let value = resolveMeta(asset)
        metaCacheStore[asset.id] = value
        return value
    }

    /// 原图/压缩副本的配对信息。原图查副本，副本查原图，都是 O(1)。
    func compressionDisplay(for asset: Asset) -> CompressionDisplay? {
        guard let index = libraryIndex, let meta = meta(asset) else { return nil }
        let key = PhotoLibraryIndex.normalize(meta.fileName)
        if let copy = index.compressedByOriginal[key] {
            return CompressionDisplay(role: .original, original: meta, copy: copy)
        }
        guard meta.importedBy.hasPrefix("local.cleanmyiphone"),
              !meta.originalFileName.isEmpty,
              let original = index.meta(for: meta.originalFileName) else { return nil }
        return CompressionDisplay(role: .copy, original: original, copy: meta)
    }

    private func resolveMeta(_ asset: Asset) -> PhotoLibraryIndex.Meta? {
        guard let index = libraryIndex else { return nil }
        // 1) 名字一样（最常见）
        if let hit = index.meta(for: asset.fileName) { return hit }
        // 2) PTP 名字和磁盘名对不上，但数字后缀一样（`HPQE7329.MP4` ↔ `IMG_7329.MP4`）
        if let hit = index.meta(matchingDigitsOf: asset.fileName) { return hit }
        // 3) 体积 + 拍摄时间都对得上
        if let hit = index.meta(matching: asset.byteSize, date: asset.createdAt) { return hit }
        // 4) **只剩拍摄时间**：视频的 PTP `byteSize` 常年不准，第 3 层对视频几乎必 miss，
        //    于是 preview 会退到「DCIM 里找不到」→ IC 单流 → 几十秒后「取不回来」。
        //    按「±2 秒 + 同种类」唯一命中兜一层，视频的预览/缩略图就能走回 AFC 快路。
        return index.meta(matchingTimeOf: asset.createdAt, isVideo: asset.kind == .video)
    }

    /// PTP 标签 + 设备库里的 subtype 合并成最终标签
    func tagSet(_ asset: Asset) -> MediaTag {
        var tags = asset.tags
        if let meta = meta(asset) {
            switch meta.subtype {
            case 10: tags.insert(.screenshot)
            case 1: tags.insert(.panorama)
            case 100, 103: tags.insert(.slomo)
            default: break
            }
            if meta.isFavorite { tags.insert(.favorite) }
            if meta.isHidden { tags.insert(.hidden) }
        }
        return tags
    }

    struct FlagStats {
        let count: Int
        let bytes: Int64
    }

    /// 隐藏 / 最近删除 / 收藏：相册库里才有，PTP 不列这些项
    @ObservationIgnored private var flagCache: [String: FlagStats] = [:]

    private func flagStats(hidden: Bool? = nil,
                           trashed: Bool? = nil,
                           favorite: Bool? = nil) -> FlagStats {
        let key = "h\(hidden.map { $0 ? 1 : 0 } ?? -1)t\(trashed.map { $0 ? 1 : 0 } ?? -1)f\(favorite.map { $0 ? 1 : 0 } ?? -1)"
        if let cached = flagCache[key] { return cached }
        guard let index = libraryIndex, !index.isEmpty else { return FlagStats(count: 0, bytes: 0) }
        var count = 0
        var bytes: Int64 = 0
        for meta in index.metaByFile.values {
            if let hidden, meta.isHidden != hidden { continue }
            if let trashed, meta.isTrashed != trashed { continue }
            if let favorite, meta.isFavorite != favorite { continue }
            count += 1
            bytes += meta.resourceBytes
        }
        let result = FlagStats(count: count, bytes: bytes)
        flagCache[key] = result
        return result
    }

    var hiddenStats: FlagStats { flagStats(hidden: true) }

    func count(for filter: LibraryFilter) -> Int {
        filterMetrics[filter]?.count ?? 0
    }

    private func invalidateCounts() {
        metaCacheStore.removeAll(keepingCapacity: true)
        albumByteCache.removeAll(keepingCapacity: true)
        flagCache.removeAll(keepingCapacity: true)
        rebuildMetrics()
    }

    private func matches(_ asset: Asset, filter: LibraryFilter) -> Bool {
        switch filter {
        case .all: return true
        case .photos: return asset.kind == .photo
        case .videos: return asset.kind == .video
        case .favorites: return meta(asset)?.isFavorite == true
        case .hidden: return meta(asset)?.isHidden == true
        case .trashed: return meta(asset)?.isTrashed == true
        case .screenshots: return tagSet(asset).contains(.screenshot)
        case .camera: return meta(asset)?.isCameraCaptured == true
        case .live: return meta(asset)?.isLive == true
        case .raw: return meta(asset)?.isRaw == true
        }
    }

    var currentScopeTitle: String {
        if let albumFilter, let album = libraryAlbums.first(where: { $0.id == albumFilter }) {
            return album.title
        }
        if case .albums = sidebarItem { return "相簿" }
        return libraryFilter.title
    }

    /// 缓存键：任何一个输入变了才重算。4600 项每次 body 都排序会卡，也容易把 SwiftUI 的
    /// 图更新栈拖垮（点「全部照片」直接崩就是这么来的）。
    @ObservationIgnored private var visibleCache: [Asset] = []
    @ObservationIgnored private var visibleKey = ""
    @ObservationIgnored var sectionCache: [(id: String, title: String, assets: [Asset])] = []
    @ObservationIgnored var sectionKey = ""

    private var visibleSignature: String {
        "\(sidebarItem)-\(sortKey)-\(ascending)-\(searchText)-\(kindFilter?.rawValue ?? "-")-\(tagFilter?.rawValue ?? 0)-\(cloudOnlyFilter)-\(assets.count)-\(libraryIndex?.generatedAt.timeIntervalSince1970 ?? 0)-\(albumFilter ?? -1)"
    }

    var visibleAssets: [Asset] {
        let key = visibleSignature
        if key == visibleKey { return visibleCache }
        let result = computeVisible()
        visibleCache = result
        visibleKey = key
        return result
    }

    private func computeVisible() -> [Asset] {
        // 这函数一次要过全量资产（每张都可能问到 meta）；PTP 目录回调抖动时
        // 会被反复触发。超时就直接记一笔，排查"界面卡几分钟"时有据可查。
        let started = Date()
        defer {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if ms > 200 {
                Self.debugLog("[perf] computeVisible \(ms)ms assets=\(assets.count) filter=\(libraryFilter)")
            }
        }
        var result = assets
        if libraryFilter != .all {
            result = result.filter { matches($0, filter: libraryFilter) }
        }
        // 相簿：成员集合本身是 `Set<String>`（归一化文件名），所以这里**按命中名去重**。
        // 同一张照片可能从几条路进来（PTP 原件 / 编辑版 `IMG_E…` / 影子资产），
        // 按名字去重才能保证「网格项数 = 二级栏张数」。
        var albumCovered: Set<String> = []
        if let albumFilter, let index = libraryIndex {
            let files = index.files(inAlbum: albumFilter)
            var kept: [Asset] = []
            for asset in result {
                let byMeta = PhotoLibraryIndex.normalize(meta(asset)?.fileName ?? asset.fileName)
                let byRaw = PhotoLibraryIndex.normalize(asset.fileName)
                let key: String
                if files.contains(byMeta) { key = byMeta }
                else if files.contains(byRaw) { key = byRaw }
                else { continue }
                if albumCovered.insert(key).inserted { kept.append(asset) }
            }
            result = kept
        }
        if let kindFilter {
            result = result.filter { $0.kind == kindFilter }
        }

        // 已隐藏 / 最近删除 / 收藏 / 截图 / 某个相簿：这些项 PTP 根本不枚举，
        // 只从 `assets` 里筛永远是空的（侧栏说有 124 张、点进去说没有）。
        // 这里用库里的影子资产补齐：按库里的标记匹配，只补 PTP 结果里没有的那些。
        if let index = libraryIndex, !index.isEmpty {
            let needsShadow = libraryFilter == .hidden || libraryFilter == .trashed
                || libraryFilter == .favorites || libraryFilter == .screenshots
                || libraryFilter == .camera || libraryFilter == .live || libraryFilter == .raw
                || albumFilter != nil || cloudOnlyFilter
            if needsShadow {
                let known = Set(result.map { PhotoLibraryIndex.normalize($0.fileName) })
                // PTP 名字和库里的名字经常对不上（CUJR5109.MOV vs IMG_5109.MOV），
                // 只按名字去重会漏，同一个视频就会出现两格：一格有时长、一格没有。
                // 这里补一条「体积 + 拍摄时间」的匹配，把已经由 PTP 覆盖的资产标记出来。
                var claimed = known
                for asset in assets {
                    if let meta = index.meta(matching: asset.byteSize, date: asset.createdAt) {
                        claimed.insert(PhotoLibraryIndex.normalize(meta.fileName))
                    }
                }
                let albumFiles = albumFilter.map { index.files(inAlbum: $0) }
                for shadow in index.shadowAssets {
                    let key = PhotoLibraryIndex.normalize(shadow.fileName)
                    // 相簿视图：上面已经按成员名精确覆盖过，别再补一遍
                    if albumFilter != nil ? albumCovered.contains(key) : claimed.contains(key) { continue }
                    guard let meta = index.meta(for: shadow.fileName) else { continue }
                    switch libraryFilter {
                    case .hidden where !meta.isHidden: continue
                    case .trashed where !meta.isTrashed: continue
                    case .favorites where !meta.isFavorite: continue
                    case .screenshots where meta.subtype != 10: continue
                    case .camera where !meta.isCameraCaptured: continue
                    case .live where !meta.isLive: continue
                    case .raw where !meta.isRaw: continue
                    default: break
                    }
                    if let albumFiles, !albumFiles.contains(key) { continue }
                    result.append(shadow)
                }
            }
        }

        // 我们自己写的压缩副本：PTP 不会枚举它们，但库里有。
        // 不补进 result，用户就看不到新的“压缩版”格子。
        if let index = libraryIndex, !index.isEmpty {
            var known = Set(result.map { PhotoLibraryIndex.normalize($0.fileName) })
            for shadow in index.shadowAssets {
                let key = PhotoLibraryIndex.normalize(shadow.fileName)
                guard !known.contains(key) else { continue }
                guard let meta = index.meta(for: shadow.fileName),
                      meta.importedBy == "local.cleanmyiphone" else { continue }
                switch libraryFilter {
                case .hidden where !meta.isHidden: continue
                case .trashed where !meta.isTrashed: continue
                case .favorites where !meta.isFavorite: continue
                case .screenshots where meta.subtype != 10: continue
                case .camera where !meta.isCameraCaptured: continue
                case .live where !meta.isLive: continue
                case .raw where !meta.isRaw: continue
                default: break
                }
                if let albumFiles = albumFilter.map({ index.files(inAlbum: $0) }),
                   !albumFiles.contains(key) { continue }
                result.append(shadow)
                known.insert(key)
            }
        }

        // 去重：**同一张照片只算一项**。
        // 目录枚举（PTP）里同一张照片可能来两条：一条是原件 `IMG_1234.HEIC`、
        // 一条是编辑版 `IMG_E1234.HEIC`，两条都归到库里同一条资产；也可能同一个
        // 路径被列了两遍。不去重的话网格里是两个一模一样的格子，底栏也会多算。
        // 键用「库里的目录 + 库里的文件名（`IMG_E1234` 归一化回 `IMG_1234`）」：
        //  · 编辑版和原件 → 同一个键，合成一项；
        //  · 不同目录下的同名文件 → 目录不同，仍然是两张真图，不会误合。
        let preDedupe = result.count
        var seen = Set<String>()
        if albumFilter == nil { result = result.filter { asset in
            // 键只认「归一化文件名」：相簿成员本身就是按文件名集合算的
            // （`files(inAlbum:)` 是 `Set<String>`），所以按名字去重才能和二级栏那个数对上。
            // 拿 meta 文件名优先，是为了把编辑版 `IMG_E1234` 和原件 `IMG_1234` 合成一项。
            let name = meta(asset)?.fileName ?? asset.fileName
            return seen.insert(PhotoLibraryIndex.normalize(name)).inserted
        } }
        if let albumFilter, let index = libraryIndex {
            Self.debugLog("[album] \(albumFilter) 命中去重前 \(preDedupe) → 最终 \(result.count)；覆盖成员 \(albumCovered.count) / \(index.files(inAlbum: albumFilter).count)")
        }

        if let tagFilter {
            result = result.filter { tagSet($0).contains(tagFilter) }
        }
        if cloudOnlyFilter {
            result = result.filter(\.isCloudOnly)
        }
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        if !keyword.isEmpty {
            result = result.filter { $0.fileName.localizedCaseInsensitiveContains(keyword) }
        }
        switch sortKey {
        case .date: result.sort { $0.createdAt < $1.createdAt }
        case .size: result.sort { $0.byteSize < $1.byteSize }
        }
        if !ascending { result.reverse() }
        result = pairCompressedCopies(result)
        return result
    }

    /// 把压缩副本排到原图后面一格（用户要的「原图后一格」）。
    /// 副本的 `ZORIGINALFILENAME` 指向原图，按这个配对。
    private func pairCompressedCopies(_ list: [Asset]) -> [Asset] {
        guard libraryIndex != nil else { return list }
        var copyByOriginal: [String: Asset] = [:]
        for asset in list {
            guard let meta = meta(asset),
                  !meta.originalFileName.isEmpty,
                  meta.originalFileName.caseInsensitiveCompare(meta.fileName) != .orderedSame
            else { continue }
            copyByOriginal[PhotoLibraryIndex.normalize(meta.originalFileName)] = asset
        }
        guard !copyByOriginal.isEmpty else { return list }

        var consumed = Set<Asset.ID>()
        var paired: [Asset] = []
        paired.reserveCapacity(list.count)
        for asset in list {
            if consumed.contains(asset.id) { continue }
            paired.append(asset)
            consumed.insert(asset.id)
            guard let meta = meta(asset) else { continue }
            let key = PhotoLibraryIndex.normalize(meta.fileName)
            if let copy = copyByOriginal[key], !consumed.contains(copy.id) {
                paired.append(copy)
                consumed.insert(copy.id)
            }
        }
        return paired
    }

    /// 体积统一口径：优先用库里的「资产全部资源合计」（`resourceBytes`，含编辑版与
    /// Live Photo 视频分量），拿不到才退 PTP 报的大小。侧栏、底栏、相簿栏都用它，
    /// 否则同一个相簿会出现「387.9 MB」和「887.1 MB」两个数。
    func totalBytes(of asset: Asset) -> Int64 {
        meta(asset)?.resourceBytes ?? asset.byteSize
    }

    var visibleBytes: Int64 { visibleAssets.reduce(0) { $0 + totalBytes(of: $1) } }
    var selectedAssets: [Asset] { visibleAssets.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedAssets.reduce(0) { $0 + totalBytes(of: $1) } }
    var pendingDeletions: Set<Asset.ID> { trash.ids }


    func clearFilters() {
        kindFilter = nil
        tagFilter = nil
        cloudOnlyFilter = false
    }

    // MARK: - 选择

    func selectSingle(_ asset: Asset) {
        selection = [asset.id]
        anchorID = asset.id
    }

    func toggle(_ asset: Asset) {
        // 已标记 → 先**撤销标记**回到正常；再点一下才是选中（2026-11 用户定的节奏）。
        // 所以取消标记不再需要单独一颗按钮：再点一次就是取消。
        if pendingDeletions.contains(asset.id) {
            unmark([asset.id])
            return
        }
        if selection.contains(asset.id) {
            selection.remove(asset.id)
        } else {
            selection.insert(asset.id)
            anchorID = asset.id
        }
    }

    func extend(to asset: Asset) {
        let list = visibleAssets
        guard let anchorID,
              let start = list.firstIndex(where: { $0.id == anchorID }),
              let end = list.firstIndex(where: { $0.id == asset.id })
        else {
            selectSingle(asset)
            return
        }
        let range = start <= end ? start...end : end...start
        // 已标记的项不进选中集合（和 toggle / selectAll 保持同一口径）
        selection = Set(list[range].map(\.id)).subtracting(pendingDeletions)
    }

    /// 全选：跳过已标记回收的（它们已经在待删名单里了）
    func selectAll() {
        selection = Set(visibleAssets.map(\.id)).subtracting(pendingDeletions)
    }

    func clearSelection() {
        selection = []
        anchorID = nil
    }

    /// 框选：把框住的并进已选。
    /// 口径按用户定的来 —— **框住的直接并入**，不做「只选框中」，
    /// 免得框一小块之前误点中的东西还得先手动取消。
    func mergeSelection(_ ids: Set<Asset.ID>) {
        guard !ids.isEmpty else { return }
        let merged = selection.union(ids)
        guard merged != selection else { return }
        selection = merged
        if anchorID == nil { anchorID = ids.first }
    }

    func move(dx: Int = 0, dy: Int = 0, extend: Bool) {
        let list = visibleAssets
        guard !list.isEmpty else { return }
        let current = anchorID.flatMap { id in list.firstIndex(where: { $0.id == id }) } ?? 0
        var target = current
        if dx != 0 { target = current + dx }
        if dy != 0 { target = current + dy * max(1, columns) }
        target = min(max(0, target), list.count - 1)
        let asset = list[target]
        if extend {
            self.extend(to: asset)
        } else {
            selectSingle(asset)
        }
        anchorID = asset.id
        if previewID != nil {
            previewID = asset.id
            loadPreviewImage(for: asset.id)
        } else {
            hoveredID = asset.id
        }
    }

    // MARK: - 悬停

    /// 鼠标进格：记下来，空格就预览它。鼠标离开时不清空——
    /// 预览层盖上来会触发 leave，清了空格就会失效。
    /// 悬停只记录"最后悬停的那一格"，离开不清空。
    /// 一离开就清的话，鼠标擦过缝隙、或者格子因为 hover 放大而抖一下，
    /// 空格就变成"没目标"，表现出来的就是"悬停到了但按空格没反应"。
    func setHover(_ id: Asset.ID, active: Bool) {
        if active { hoveredID = id }
    }

    /// 记下当前这一格在 root 坐标系里的矩形：预览卡片从它的中心长出来。
    /// 只在鼠标进入时写一次，不挂 preference —— 5000 张的网格经不起滚动重算。
    func setPreviewAnchor(_ rect: CGRect) {
        previewAnchorRect = rect
    }

    // MARK: - 待删 / 回收站

    /// 预览里给当前这一项打回收标记。
    /// **不自动跳到下一张**（2026-11 用户明确要求）：标记 / 取消标记 / 选中都是
    /// 就地改状态，画面留在原地 —— 顶栏的状态胶囊会立刻变成「已标记回收」，
    /// 反馈已经够了；自动跳走反而让人不知道刚才那一下动的是哪张。
    /// 想换下一张就 ← → 或点顶栏的「下一张」。
    func trashCurrentPreview() {
        guard let id = previewID, let asset = assets.first(where: { $0.id == id }) else { return }
        trash.add([asset], deviceID: device?.id ?? "unknown")
        selection.remove(id)
    }

    /// 预览里切换「当前这一项」的选中状态。
    /// **已经标记回收的不许再选中** —— 它已经在待删名单里了，再打勾只会自相矛盾。
    func togglePreviewSelection() {
        guard let id = previewID, !pendingDeletions.contains(id) else { return }
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
            anchorID = id
        }
    }

    /// 取消标记（把这一项从待删名单里拿回来）
    func unmarkCurrentPreview() {
        guard let id = previewID else { return }
        trash.remove(ids: [id])
    }

    /// 框选落到已选 / 已标记的块上：反过来把标记撤掉
    func unmark(_ ids: Set<Asset.ID>) {
        guard !ids.isEmpty else { return }
        trash.remove(ids: ids)
    }

    /// 框选结果怎么落到状态里（模式在拖拽开始时按"按住的那一格"定好）。
    /// **框选不再能取消标记**（2026-11 用户定的）：取消标记只能人工点格子右上角的叉，
    /// 或者预览里按 ⌫。框到已标记的项就当没框到 —— 已标记的不进选中集合。
    func marqueeApply(_ hits: Set<Asset.ID>, mode: MarqueeMode) {
        guard !hits.isEmpty else { return }
        switch mode {
        case .select:
            let addable = hits.subtracting(pendingDeletions)
            guard !addable.isEmpty else { return }
            mergeSelection(addable)
        case .deselect:
            selection.subtract(hits)
        }
    }

    /// 「标记回收」：一步到位，**不弹二次确认**。
    /// 回收站本身就是那道保险 —— 标记只是打记号，真正的删除还要再走一次
    /// 「彻底删除」，一共两层，够了。再叠一层确认等于三次点击才动到一张照片。
    func markSelectedForRecycle() {
        let chosen = selectedAssets
        guard !chosen.isEmpty else { return }
        trash.add(chosen, deviceID: device?.id ?? "unknown")
        clearSelection()
        flash("已标记 \(chosen.count) 项到回收站")
    }

    /// 回收站里单独几条「彻底删除」：和清空走同一台引擎，只是范围小
    func deleteFromTrash(ids: [Asset.ID]) async {
        let set = Set(ids)
        let entries = trash.entries.filter { set.contains($0.id) }
        guard !entries.isEmpty, !isPurging else { return }
        await purge(entries)
    }

    /// 底栏那句一次性提示（2.4 秒后消失），不写进 purgeMessage
    private var provisionalMessageTask: Task<Void, Never>?
    func flash(_ text: String) {
        provisionalMessage = text
        provisionalMessageTask?.cancel()
        provisionalMessageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            self?.provisionalMessage = nil
        }
    }

    func restoreFromTrash(ids: [Asset.ID]) {
        trash.remove(ids: ids)
    }

    func emptyTrash() async {
        await purge(trash.entries)
    }

    /// 真删：只有这一个地方会动设备。清空回收站、回收站里删选中的几条，都走它。
    ///
    /// 全流程**看得见**（2026-11 用户要求）：
    /// 1. `purgeProgress` 非 nil → 盖一层「正在删除」弹窗，跟着设备回执更新；
    /// 2. 删完 `purgeReport` 非 nil → 弹结果单，成功/失败各多少，**失败的逐条给出原因**；
    /// 3. 底栏再留一句短的，弹窗关了也看得到。
    private func purge(_ entries: [TrashStore.Entry]) async {
        guard !entries.isEmpty, !isPurging else { return }
        isPurging = true
        purgeReport = nil
        purgeProgress = PurgeProgress(
            total: entries.count,
            bytesTotal: entries.reduce(0) { $0 + $1.byteSize },
            currentName: entries.first?.fileName ?? "",
            batchFrom: 1,
            batchTo: min(PurgeEngine.batchSize, entries.count)
        )

        let engine = PurgeEngine(trash: trash, source: { [self] in source })
        let outcome = await engine.purge(entries) { [weak self] progress in
            self?.purgeProgress = progress
        }
        isPurging = false
        purgeProgress = nil

        let removed = Set(outcome.succeeded)
        assets.removeAll { removed.contains($0.id) }
        invalidateCounts()
        thumbnails = thumbnails.filter { !removed.contains($0.key) }

        purgeReport = PurgeReport(
            total: outcome.total,
            succeededIDs: outcome.succeeded,
            succeededBytes: outcome.succeededBytes,
            failures: outcome.failures,
            aborted: outcome.aborted,
            skipped: outcome.skipped
        )

        if outcome.failures.isEmpty {
            purgeMessage = "已彻底删除 \(outcome.succeeded.count) 项，释放 "
                + ByteCountFormatter.string(fromByteCount: outcome.succeededBytes, countStyle: .file)
        } else {
            let first = outcome.failures.first?.reason ?? "未知原因"
            purgeMessage = "\(outcome.summary)：\(first)"
        }
    }

    /// 结果单里那个「重试失败的 N 项」：失败项一直留在回收站，直接再删一遍
    func retryFailedPurge() async {
        guard let report = purgeReport, !report.failures.isEmpty, !isPurging else { return }
        let ids = Set(report.failures.map(\.id))
        let entries = trash.entries.filter { ids.contains($0.id) }
        guard !entries.isEmpty else {
            purgeReport = nil
            flash("这些项已经不在回收站里了")
            return
        }
        purgeReport = nil
        await purge(entries)
    }

    func dismissPurgeReport() {
        purgeReport = nil
    }

    // MARK: - 预览

    /// 预览目标：鼠标悬停 > 已选 > 锚点 > 第一项。点选只负责选中，不负责预览。
    private var previewTarget: Asset.ID? {
        let list = visibleAssets
        if let hoveredID, list.contains(where: { $0.id == hoveredID }) { return hoveredID }
        if let first = selection.first, list.contains(where: { $0.id == first }) { return first }
        if let anchorID, list.contains(where: { $0.id == anchorID }) { return anchorID }
        return list.first?.id
    }

    func openPreview() {
        // 库索引没好之前不给预览：那个阶段取原文件只能走 IC 的单流下载，
        // 大视频会等到超时，体验很差。先让用户看到索引进度。
        guard !dataPaused else { return }
        guard libraryIndex != nil || usingFixture else { return }
        guard let target = previewTarget else { return }
        // 退出动画还没播完就又要打开：把待拆的任务作废，直接换目标
        closeTask?.cancel()
        closeTask = nil
        isClosingPreview = false
        previewID = target
        loadPreviewImage(for: target)
    }

    /// 请求关闭：**先播 180 ms 的退出动画，再拆**。
    /// 只做透明度淡出的话，缩略图是"凭空消失"；原生 Quick Look 会缩回原位。
    func closePreview() {
        guard previewID != nil, !isClosingPreview else { return }
        isClosingPreview = true
        // 取回立刻作废，不等动画：不掐掉的话它还会占着那条串行下载通道跑到收尾
        DeviceFiles.shared.cancelPreviewDownload()
        DeviceFiles.shared.setPreviewWaiting(false)
        previewWaitNotice?.cancel()
        previewWaitNotice = nil
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            self?.teardownPreview()
        }
    }

    @ObservationIgnored private var closeTask: Task<Void, Never>?

    /// 真正拆除预览状态（播放器、缓存引用、进度数字全部归零）
    private func teardownPreview() {
        closeTask = nil
        isClosingPreview = false
        previewID = nil
        previewImage = nil
        previewVideoURL = nil
        previewLoading = false
        previewProgressText = ""
        previewStageText = ""
        previewError = nil
        previewBytesDone = 0
        previewBytesTotal = 0
        // 缓存里的完整文件不能删：播放器可能还拿着它，删了就是"播放不可用"。
        // 半截文件（用户中途关掉的）清掉，别留在原地冒充完整视频。
        purgeUncachedPreviewFiles()
        DeviceFiles.emptyDirectory(DeviceFiles.rawCacheDirectory.appendingPathComponent("preview",
                                                                                     isDirectory: true))
    }

    /// 清掉预览目录里**没进缓存**的文件：用户中断后留下的半截。
    /// 已缓存的（最近 3 个）保留，预览副本仍会在退出 App / 下次启动时统一清掉。
    private func purgeUncachedPreviewFiles() {
        // /var/folders 在 TMPDIR 里常常是符号链接，两边都解析一次再比路径
        let keep = Set(previewFileCache.values.map { $0.resolvingSymlinksInPath().path })
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: Self.previewDirectory, includingPropertiesForKeys: nil) else { return }
        for url in items where !keep.contains(url.resolvingSymlinksInPath().path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func stepPreview(_ delta: Int) {
        let list = visibleAssets
        guard !isClosingPreview,
              let previewID, let index = list.firstIndex(where: { $0.id == previewID }) else { return }
        let next = min(max(0, index + delta), list.count - 1)
        self.previewID = list[next].id
        anchorID = list[next].id
        loadPreviewImage(for: list[next].id)
    }

    /// 本次会话里已经取回的视频文件：反复空格开关同一个视频不再重下，
    /// 也不会出现"取完就被删、播放器拿着失效路径 → 播放不可用"。
    @ObservationIgnored private var previewFileCache: [Asset.ID: URL] = [:]
    /// 预览迟迟没有第一个字节时的兜底提示（1.5 秒），关预览/换目标要作废
    @ObservationIgnored private var previewWaitNotice: Task<Void, Never>?
    private static let previewCacheLimit = 3

    private func cachedPreviewFile(for id: Asset.ID) -> URL? {
        guard let url = previewFileCache[id],
              FileManager.default.fileExists(atPath: url.path) else {
            previewFileCache[id] = nil
            return nil
        }
        return url
    }

    private func rememberPreviewFile(_ url: URL, for id: Asset.ID) {
        previewFileCache[id] = url
        // 只留最近 3 个，别把临时盘撑爆
        if previewFileCache.count > Self.previewCacheLimit {
            let stale = previewFileCache.keys.filter { $0 != id }
            for key in stale.prefix(previewFileCache.count - Self.previewCacheLimit) {
                if let url = previewFileCache.removeValue(forKey: key) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    static let previewDirectory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanmyiphone-preview", isDirectory: true)
        // 权限 0700：这里放的是**整份原视频**，默认 0755 会被同机其他账户读走
        DeviceFiles.makePrivateDirectory(url)
        return url
    }()

    private func loadPreviewImage(for id: Asset.ID) {
        // 预览是用户主动操作，优先给它带宽：把还没开始的缩略图请求全丢掉
        pendingThumbs.removeAll()
        DeviceFiles.shared.cancelPending()
        // 换目标 / 重新取回，一律把上一次还没下完的作废。
        // **不能**只写在 `if previewID != id` 分支里：openPreview / stepPreview / move
        // 都是「先给 previewID 赋新值、再调这里」，那个判断恒不成立，
        // 作废令牌等于从来没生效过 —— 旧视频占着通道跑到收尾，新视频排在它后面，
        // 用户看到的就是「打开了却没反应、数字还是上一个」。
        DeviceFiles.shared.cancelPreviewDownload()
        if previewID != id {
            previewBytesDone = 0
            previewBytesTotal = 0
        }
        if libraryIndex == nil, !usingFixture {
            previewProgressText = "" 
        }
        // 先用网格里已有的 480px 立刻显示，再后台换大图，切换不空屏
        previewImage = thumbnails[id]
        previewVideoURL = nil
        previewLiveVideoURL = nil
        guard let asset = asset(withID: id) else { return }

        if asset.kind == .video {
            // 这次会话里已经取回来过 → 直接播，不再重下
            if let cached = cachedPreviewFile(for: id) {
                previewLoading = false
                previewProgressText = ""
                previewVideoURL = cached
                return
            }
            previewLoading = true
            previewProgressText = ""
            previewStageText = libraryIndex == nil ? "正在读取相册索引" : "正在取回视频"
            previewError = nil
            previewBytesDone = 0
            previewBytesTotal = 0
            // 令牌要在起下载**之前**取：之后任何一次换目标都会让它过期
            let token = DeviceFiles.shared.previewToken()
            // 预览要通道了，缩略图先让路（共用队列时这条是唯一保命手段）
            DeviceFiles.shared.setPreviewWaiting(true)
            DeviceFiles.trace("ui preview video \(asset.fileName) lib=\(libraryIndex != nil)")
            // 1.5 秒还没收到第一个字节：多半是在等设备通道（或降级到了 IC 单流），
            // 这时候只转圈会让人以为卡死，说清楚在等什么
            previewWaitNotice?.cancel()
            previewWaitNotice = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.previewID == id, self.previewLoading, self.previewBytesDone == 0 else { return }
                self.previewStageText = "正在等待设备通道"
            }
            Task {
                // 不管成功、失败还是被作废，都要放开让路；
                // 让路期间被放弃的缩略图要让格子重新请求一次，不然那几格一直空着
                defer {
                    if self.previewID == id {
                        DeviceFiles.shared.setPreviewWaiting(false)
                        if DeviceFiles.shared.takePreviewYielded() { self.bumpThumbEpoch() }
                    }
                }
                guard self.previewID == id else { return }
                self.previewStageText = "正在取回视频"
                var got: (url: URL, planned: Int64)?
                for attempt in 0..<2 {
                    guard self.previewID == id else { return }
                    got = await self.downloadOriginal(
                        for: asset,
                        to: Self.previewDirectory,
                        isCancelled: { DeviceFiles.shared.isPreviewCancelled(token) },
                        onProgress: { done, total in
                            Task { @MainActor in
                                // 进度必须归属到发起它的那次预览：
                                // 以前这里直接写共享状态，换目标后数字还是上一个视频的
                                guard self.previewID == id else { return }
                                if done > 0, self.previewBytesDone == 0 {
                                    DeviceFiles.trace("ui first bytes \(done)B")
                                }
                                self.previewBytesDone = done
                                self.previewBytesTotal = total
                                // 真在取数据了：把「等待设备通道」换回正常阶段
                                if done > 0, self.previewStageText == "正在等待设备通道" {
                                    self.previewStageText = "正在取回视频"
                                }
                                // 报字节，不报百分比：进度条骗人的时候，字节数是实打实的
                                self.previewProgressText = total > 0
                                    ? "\(Self.sizeText(done)) / \(Self.sizeText(total))"
                                    : Self.sizeText(done)
                            }
                        })
                    if got != nil { break }
                    if attempt == 0, self.previewID == id {
                        previewStageText = "第一次没取到，重试中"
                    }
                }
                if self.previewID != id { return }
                self.previewLoading = false
                if let got {
                    // 只有完整文件才进缓存：半截文件留在缓存里 = 下次"播放失败"
                    let size = (try? FileManager.default.attributesOfItem(atPath: got.url.path))?[.size] as? Int64 ?? 0
                    // 基准只认 AFC 报的**设备真实大小**（st_size 是准的）。
                    // IC 的 totalUnitCount 对大视频常偏大，PTP 的 byteSize 更不准，
                    // 拿它们判就会把「其实已经取完」误报成「取回不完整」。
                    // planned == 0 表示这次没有可信基准，直接放行。
                    if got.planned > 0, size > 0, size < got.planned {
                        try? FileManager.default.removeItem(at: got.url)
                        self.previewError = "取回不完整，再试一次"
                        return
                    }
                    self.rememberPreviewFile(got.url, for: id)
                    self.previewVideoURL = got.url
                } else {
                    self.previewError = DeviceFiles.shared.lastError ?? "取不回来"
                }
            }
        } else {
            // **有缩略图也照样保持 loading**：用户看到的是一张 480px 的糊图，
            // 原图动辄 5–20 MB，中间那段必须有交代 —— 跟视频取回时一样报字节。
            // 以前这里是 `previewLoading = previewImage == nil`，有缩略图时进度直接关了，
            // 屏幕上就是糊图晾着，看不出在等什么、还要多久。
            previewLoading = true
            previewProgressText = ""
            previewBytesDone = 0
            previewBytesTotal = 0
            previewStageText = libraryIndex == nil ? "正在读取相册索引" : "正在取回原尺寸"
            previewError = nil
            let token = DeviceFiles.shared.previewToken()
            // 实况照片：另起一条任务取视频分量，不挡静态图。
            // 静态图先出来，视频到了预览自己动起来 —— 这是 iPhone 相册的手感。
            if isLivePhoto(asset) {
                loadLiveVideo(for: asset, id: id, token: token)
            }
            Task {
                // 预览要原图：整份下载 → 原生尺寸解码，不降采样、不重编码。
                var cg: CGImage?
                if let got = await self.downloadOriginal(
                    for: asset,
                    to: DeviceFiles.previewPhotoDirectory,
                    isCancelled: { DeviceFiles.shared.isPreviewCancelled(token) },
                    onProgress: { done, total in
                        Task { @MainActor in
                            // 进度必须归属到发起它的那次预览（换目标后旧数字会串台）
                            guard self.previewID == id else { return }
                            self.previewBytesDone = done
                            self.previewBytesTotal = total
                            self.previewProgressText = total > 0
                                ? "\(Self.sizeText(done)) / \(Self.sizeText(total))"
                                : Self.sizeText(done)
                        }
                    }
                ), let decoded = DeviceFiles.decodeOriginal(got.url, asset: asset) {
                    cg = decoded
                } else {
                    // IC 取不到才退回 AFC
                    cg = await DeviceFiles.shared.originalImage(
                        for: asset,
                        libraryName: self.meta(asset)?.fileName)
                }
                guard self.previewID == id else { return }
                if let cg {
                    self.previewImage = NSImage(cgImage: cg,
                                                size: NSSize(width: cg.width, height: cg.height))
                }
                self.previewLoading = false
                self.previewProgressText = ""
                self.previewBytesDone = 0
                self.previewBytesTotal = 0
                if cg == nil { self.previewError = "取不到这张图（设备没回数据）" }
            }
        }
    }

    // MARK: - 实况照片

    /// 是不是实况照片。库索引最准（`subtype == 2 && playbackStyle == 3`，
    /// 那条口径把「拍的时候关了实况」的 4 条 subtype=2 排除掉了）；
    /// 库还没到、或者这条匹配不上时，退 PTP 的 groupUUID 标记。
    func isLivePhoto(_ asset: Asset) -> Bool {
        if let meta = meta(asset) { return meta.isLive }
        return asset.tags.contains(.live)
    }

    /// 取实况照片的视频分量。
    ///
    /// 文件布局是真机实测出来的：**同目录、同 basename、扩展名 `.MOV`**
    /// （`--probe-livefiles`：DCIM 下 410 组「图 + 同名视频」）。
    /// 所以不需要去解析 `ZINTERNALRESOURCE`，按名字拼路径就行。
    ///
    /// 走预览通道，和原图那条**串行**：原图先出、视频随后，
    /// 用户看到的是「静态图 → 自己动起来」，两条不会互相抢带宽。
    private func loadLiveVideo(for asset: Asset, id: Asset.ID, token: Int) {
        guard let meta = meta(asset) else { return }
        let stem = (meta.fileName as NSString).deletingPathExtension
        guard !stem.isEmpty else { return }

        let dir = meta.directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = dir.uppercased().hasPrefix("DCIM") ? "/\(dir)" : "/DCIM/\(dir)"
        // 实况的视频分量固定是 .MOV；再把小写和 .MP4 兜上，
        // 老机器/导入来源偶尔会不一样
        let candidates = ["MOV", "mov", "MP4", "mp4"].map { "\(prefix)/\(stem).\($0)" }
        DeviceFiles.trace("ui live video \(asset.fileName) 试 \(candidates.first ?? "-")")

        Task { [weak self] in
            guard let self else { return }
            for path in candidates {
                guard self.previewID == id,
                      !DeviceFiles.shared.isPreviewCancelled(token) else { return }
                if let hit = await DeviceFiles.shared.downloadByDevicePath([path],
                                                                           to: Self.previewDirectory) {
                    guard self.previewID == id else { return }
                    self.previewLiveVideoURL = hit.url
                    DeviceFiles.trace("ui live video 到手 \(hit.url.lastPathComponent) \(hit.received)B")
                    return
                }
            }
            DeviceFiles.trace("ui live video 取不到：\(asset.fileName)")
        }
    }

    /// 取原始文件：优先用 ImageCaptureCore 自己的下载接口。
    /// AFC 那条路要靠文件名去 /DCIM 索引里匹配，PTP 名字和磁盘名字对不上时就报
    /// 「DCIM 里找不到」；IC 是按设备对象句柄取的，不存在这个问题。
    /// 预览取原文件前，等相册库索引就绪（最多 10 秒）。
    /// 库里有 `ZDIRECTORY`/`ZFILENAME` 才能走 AFC 的 36 MB/s；
    /// 库没到就只能退回 IC 的单流下载，几百 MB 的视频会慢到超时。
    private func waitForLibraryIndex(maxSeconds: Double = 20, for id: Asset.ID? = nil) async {
        guard libraryIndex == nil, !usingFixture else { return }
        let deadline = Date().addingTimeInterval(maxSeconds)
        while libraryIndex == nil, Date() < deadline {
            // 目标已经被换掉了就别再往界面写阶段文案（会盖掉新视频的进度）
            if let id, previewID != id { return }
            // 让用户看到"在等什么"：库索引读到哪了
            previewStageText = "正在读取相册索引"
            previewProgressText = libraryBytesTotal > 0
                ? "\(Self.sizeText(libraryBytesDone)) / \(Self.sizeText(libraryBytesTotal))"
                : ""
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// 返回 `(url, planned)`：`planned` 是**可信的**完成基准字节数，0 表示这次没有基准
    /// （IC / 名字匹配两条路都给不出准数）。完整性判定只认它，不认界面上的进度状态。
    private func downloadOriginal(for asset: Asset,
                                  to directory: URL,
                                  isCancelled: (() -> Bool)? = nil,
                                  onProgress: ((Int64, Int64) -> Void)? = nil) async -> (url: URL, planned: Int64)? {
        await waitForLibraryIndex(for: asset.id)
        // 1) 最快且最准：库里有 `/ZDIRECTORY/ZFILENAME`，直接用绝对路径走 AFC（实测 36 MB/s）。
        //    IC 的 PTP 下载是单流小包，几百 MB 的视频会慢到超时（用户看到的 30 秒"没取到"）。
        if let meta = meta(asset) {
            var paths: [String] = []
            let dir = meta.directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if dir.uppercased().hasPrefix("DCIM") {
                paths.append("/\(dir)/\(meta.fileName)")
            } else {
                paths.append("/DCIM/\(dir)/\(meta.fileName)")
            }
            paths.append("/\(dir)/\(meta.fileName)")
            DeviceFiles.trace("download path=\(paths[0]) alt=\(paths[1])")
            if let hit = await DeviceFiles.shared.downloadByDevicePath(paths, to: directory,
                                                                       expected: asset.byteSize,
                                                                       onProgress: onProgress) {
                return (hit.url, hit.planned)
            }
            DeviceFiles.trace("AFC 取不到，降级 IC：\(asset.fileName) err=\(DeviceFiles.shared.lastError ?? "-")")
        } else {
            DeviceFiles.trace("库里没有这条 → 直接走 IC：\(asset.fileName)")
        }
        // 2) 库里没有这条 / 库路径打不开：**先走 /DCIM 名字索引（AFC，36 MB/s）**。
        //    PTP 报的名字看着是随机的（`HPQE7329.MP4`），磁盘上往往就是这个名字，
        //    精确名匹配命中率不低；比 IC 单流快一个数量级，也不会"开头几秒一个字节都没有"。
        if let url = await DeviceFiles.shared.download(fileName: asset.fileName,
                                                       libraryName: meta(asset)?.fileName,
                                                       to: directory,
                                                       priority: true) {
            DeviceFiles.trace("AFC 名字匹配命中：\(asset.fileName)")
            return (url, 0)
        }
        // 3) 最后才是 IC 单流兜底（按对象句柄取，几十 MB 要等十几秒）
        if let ptp = source as? PTPBridge {
            if let url = await ptp.downloadOriginal(for: asset, to: directory,
                                                    onProgress: onProgress,
                                                    isCancelled: isCancelled) {
                return (url, 0)
            }
        }
        return nil
    }

    /// 按 id 找资产：PTP 枚举结果 → 库里的影子资产（已隐藏 / 最近删除 只存在这里）
    func asset(withID id: Asset.ID) -> Asset? {
        if let hit = assets.first(where: { $0.id == id }) { return hit }
        return libraryIndex?.shadowAssets.first { $0.id == id }
    }

    /// 预览层显示的项（可能不在当前筛选里）
    var previewAsset: Asset? {
        guard let previewID else { return nil }
        return asset(withID: previewID)
    }

    // MARK: - 缩略图

    /// 同时在飞的缩略图请求上限
    private static let maxInFlightThumbs = 6
    /// 超出上限时排队的格子
    @ObservationIgnored private var pendingThumbs: [Asset] = []

    /// 这个格子现在还值得为它去设备上取图吗（预览中的也算）
    private func isThumbnailWanted(_ id: Asset.ID) -> Bool {
        if previewID == id { return true }
        return visibleAssets.contains { $0.id == id }
    }

    /// 缩略图诊断日志：只记「请求了什么、为什么没出图」，不记图片内容。
    /// 排查"某一屏全空"时让用户复现后直接看这个文件。
    @ObservationIgnored private var thumbLogWrites = 0
    /// 这一轮里确定取不到的资产（设备端没缓存 + PTP 不回数据）。
    /// 不清掉的话，格子被复用/滚动回来会again 等 8 秒视频超时；`bumpThumbEpoch` 时清空重试。
    @ObservationIgnored private var thumbUnavailable: Set<Asset.ID> = []

    func thumbTrace(_ text: String) {
        guard thumbLogWrites < 4000 else { return }
        thumbLogWrites += 1
        let base = TraceRegistry.dataDirectory
        DeviceFiles.makePrivateDirectory(base)
        let url = base.appendingPathComponent("thumb-log.txt")
        let line = Date().formatted(.dateTime.hour().minute().second()) + " " + text + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// 换排序 / 换相簿时调用：作废上一屏还在排队的请求，让格子重新取一次图。
    /// 只 `cancelPending` 不清 `thumbTasks` 是不够的 —— 旧任务还占着位置，
    /// `requestThumbnail` 会以为"已经在取了"直接返回，那些格子就永远空着。
    func bumpThumbEpoch() {
        thumbEpoch &+= 1
        // 换排序 / 换相簿 / 目录重枚举：给"上一轮取不到"的一次重试机会
        thumbUnavailable.removeAll()
        for (id, task) in thumbTasks where thumbnails[id] == nil {
            task.cancel()
        }
        thumbTasks = thumbTasks.filter { thumbnails[$0.key] != nil }
        DeviceFiles.shared.cancelPending()
    }

    func requestThumbnail(_ asset: Asset) {
        guard !dataPaused else { return }
        if thumbnails[asset.id] != nil || thumbTasks[asset.id] != nil { return }
        // 一屏几百个格子会同时发请求。不设上限的话，几百个 Task 一起挤在
        // 主线程和 AFC 队列上，表现就是"整个界面卡住、谁也不出图"。
        // 超出的先记下来，等前面的做完再补（drainPending）。
        guard thumbTasks.count < Self.maxInFlightThumbs else {
            if !pendingThumbs.contains(where: { $0.id == asset.id }) {
                pendingThumbs.append(asset)
            }
            return
        }
        startThumbTask(asset)
    }

    private func startThumbTask(_ asset: Asset) {
        guard thumbTasks[asset.id] == nil, thumbnails[asset.id] == nil else { return }
        thumbTrace("req \(asset.fileName) \(asset.byteSize)B \(asset.kind)")
        thumbTasks[asset.id] = Task { [weak self] in
            guard let self else { return }
            await self.loadThumbnail(asset)
            await MainActor.run {
                self.thumbTasks[asset.id] = nil
                self.drainPendingThumbs()
            }
        }
    }

    private func drainPendingThumbs() {
        while thumbTasks.count < Self.maxInFlightThumbs, !pendingThumbs.isEmpty {
            let next = pendingThumbs.removeFirst()
            if thumbnails[next.id] == nil, thumbTasks[next.id] == nil, isThumbnailWanted(next.id) {
                startThumbTask(next)
            }
        }
    }

    private func loadThumbnail(_ asset: Asset) async {
        // 滚动时快速掠过格子：等一小会儿再下，格子被回收就不为它拉原文件。
        // 现在主路径是「读设备端缩略图缓存」（单张 3–4 ms），不用再等 140 ms 那么久，
        // 否则一屏格子的首帧延迟全被这段 sleep 占着。
        try? await Task.sleep(nanoseconds: 60_000_000)
        if Task.isCancelled { return }

        // 切排序 / 换相簿 / 换筛选之后，上一屏的排队请求就不再需要了
        let stillWanted = await MainActor.run { isThumbnailWanted(asset.id) }
        guard stillWanted else {
            thumbTrace("drop(不在当前视图) \(asset.fileName)")
            return
        }
        // 这一轮已经确认取不到（设备端没缓存、PTP 也不回）：别再为它等一次超时
        let alreadyMissing = await MainActor.run { thumbUnavailable.contains(asset.id) }
        if alreadyMissing {
            thumbTrace("skip(本轮已确认取不到) \(asset.fileName)")
            return
        }

        // 1) **设备自己的缩略图缓存**：`/PhotoData/Thumbnails/V2/DCIM/<目录>/<文件名>/5005.JPG`。
        //    照片和视频都有，一张 14–86 KB，实测单张 3–4 毫秒（iMazing 也读这套）。
        //    这条必须排第一：它比问 PTP（超时+串行）和下整份原图（DNG 能到 72 MB）快三个数量级。
        let info = await MainActor.run { meta(asset) }
        if let data = await DeviceFiles.shared.deviceThumbnail(directory: info?.directory,
                                                              fileName: info?.fileName ?? asset.fileName) {
            await MainActor.run {
                if let image = NSImage(data: data) {
                    thumbTrace("cache-thumb \(asset.fileName) \(data.count)B")
                    storeThumbnail(asset.id, image)
                }
            }
            return
        }

        // 2) 设备端缩略图（PTP 主动请求）：缓存里没有（刚拍、刚导入、iCloud 未落地）时才走
        if let image = await source.thumbnail(for: asset, maxPixel: 480) {
            await MainActor.run {
                thumbTrace("device-thumb \(asset.fileName)")
                storeThumbnail(asset.id, image)
            }
            return
        }

        // 3) 视频：这两条都不给就跳过。
        //    网格里下整片（一屏几 GB）不现实，抽帧那套已经删掉了。
        //    设备端缓存没有 + PTP 不回，就是"设备上真的没有这张图"（实测全库 4932 条里
        //    只有极少数这种），登记下来别让它每次滚回来都再等 8 秒。
        if asset.kind == .video {
            await MainActor.run {
                thumbUnavailable.insert(asset.id)
                thumbTrace("no-thumb \(asset.fileName)（设备端缓存没有，PTP 未回数据）")
            }
            return
        }

        // 4) 照片：AFC 下原图 + 降采样
        let data = await DeviceFiles.shared.thumbnailData(for: asset,
                                                          libraryName: info?.fileName,
                                                          maxPixel: 480)
        await MainActor.run {
            // NSImage 一律在主线程创建，后台创建的拿到这里渲染是黑图
            if let data, let image = NSImage(data: data) {
                thumbTrace("ok(照片) \(asset.fileName) \(data.count)B")
                storeThumbnail(asset.id, image)
            } else {
                thumbUnavailable.insert(asset.id)
                thumbTrace("fail(照片) \(asset.fileName) err=\(DeviceFiles.shared.lastError ?? "-")")
            }
        }
    }

    // MARK: - 不留痕模式（退出即清空）

    /// 老版本留过一个「自动清空」开关（UserDefaults 里的 `cmi.autoPurge`）。
    /// 现在不留痕是**无条件**的，那个 key 就成了纯痕迹，启动时顺手删掉。
    static let legacyAutoPurgeKey = "cmi.autoPurge"

    /// 手动清空之后**暂停一切重建**：不重扫、不重生成缩略图。
    /// 想继续用就点「重新读取」。
    private(set) var dataPaused = false

    /// 删掉所有落盘的设备数据。清单只有一份，在 `TraceRegistry` 里。
    /// 返回**没删掉的**条目 —— 删不动要能看见，不能让界面假装"已清空"。
    @discardableResult
    nonisolated static func purgeLocalDataOnDisk() -> [String] {
        TraceRegistry.purgeAll()
    }

    /// 上次清空有没有漏：界面要如实显示
    private(set) var purgeLeftovers: [String] = []

    /// 退出回调里拿不到 store 实例，用这个静态入口。**无条件清**。
    nonisolated static func purgeOnTerminate() {
        purgeLocalDataOnDisk()
        // 偏好 plist 是 cfprefsd 在退出那一刻才写盘的，进程内删不掉 ——
        // 挂一个退出后的一次性清理（见 `TraceRegistry.schedulePostExitSweep`）
        TraceRegistry.schedulePostExitSweep()
    }

    /// 立即清空。**磁盘 + 内存一起清**：清完界面是真的空着，不是"还记得但看不到"。
    /// 想恢复只能点「重新读取」。
    func purgeLocalData() {
        // 先把还在跑的缩略图任务按停，否则删完目录它又被写回来，
        // 回查就会看到「thumbs 没删掉」。
        pendingThumbs.removeAll()
        for (_, task) in thumbTasks { task.cancel() }
        thumbTasks.removeAll()
        DeviceFiles.shared.cancelPending()
        thumbnails.removeAll()
        thumbOrder.removeAll()

        purgeLeftovers = Self.purgeLocalDataOnDisk()

        // 内存里那份库索引也丢掉：硬盘上什么都没有了，留它在内存里
        // 只会让侧栏继续显示张数、点进去却一张图都出不来。
        libraryIndex = nil
        libraryAlbums = []
        libraryStatus = nil
        libraryStarted = false
        libraryDone = false
        librarySkipped = false
        libraryFailureCount = 0
        libraryAutoRetryStopped = false
        metaCacheStore.removeAll()
        albumByteCache.removeAll()
        flagCache.removeAll()
        filterMetrics = [:]
        metricsReady = false
        assets = []
        selection.removeAll()
        thumbUnavailable.removeAll()
        trash.removeAll()
        invalidateCounts()

        // 清完就停在这：不重扫、不重生成缩略图，等用户点「重新读取」
        dataPaused = true
        previewError = nil
        purgeMessage = purgeLeftovers.isEmpty ? "已清空（磁盘和内存），点「重新读取」重新读设备"
            : "有 \(purgeLeftovers.count) 项没删掉：\(purgeLeftovers.joined(separator: "、"))"
    }

    /// 手动恢复：解除暂停并**真的重新读一遍**设备（现在没有快照可用了）
    /// 左下角那颗「重新读取」：**任何状态都能点**（2026-11 用户定的）。
    /// - 清空过（暂停态）→ 解除暂停、丢掉内存里那份，从头读；
    /// - 没清空过 → 等价于点一次刷新（重扫照片目录 + 重读相册索引）。
    func resumeReading() {
        guard !isScanning else { return }
        if dataPaused {
            dataPaused = false
            purgeMessage = nil
            libraryIndex = nil
            libraryAlbums = []
            libraryStarted = false
            libraryDone = false
            libraryStatus = nil
            bumpThumbEpoch()
        }
        Task { await refreshDevice() }
    }

    // MARK: - 缩略图缓存

    /// 内存里的缩略图按「最近出现」淘汰。
    /// 以前是 `count > 2000 → removeAll()`：5270 张的库滑到底再滑回来，全部从设备重下。
    /// 现在只砍最老的 600 张，磁盘缓存还在，回头滚过去是读本地文件，不再走设备。
    @ObservationIgnored private var thumbOrder: [Asset.ID] = []

    private func storeThumbnail(_ id: Asset.ID, _ image: NSImage) {
        if thumbnails[id] == nil { thumbOrder.append(id) }
        thumbnails[id] = image
        guard thumbOrder.count > 1400 else { return }
        for old in thumbOrder.prefix(600) { thumbnails[old] = nil }
        thumbOrder.removeFirst(600)
    }

    /// 缩略图缓存目录当前体积

    
    /// 清空缩略图缓存：删磁盘、清内存、让格子重新取
    
    // MARK: - 键盘

    /// 窗口级 keyDown（`KeyMonitor` 挂的 local monitor 送进来）。返回 true = 已处理、事件被吞。
    ///
    /// 不再用 `.onKeyPress`：那套要求焦点正好落在根视图上，鼠标点过预览里的键帽按钮、
    /// 或者视频播放器拿到 first responder 之后就收不到键 —— 用户报的
    /// 「预览里按退格没反应」就是这个。这里与焦点无关。
    @discardableResult
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // 删除中 / 结果单开着：键盘一律让给那两块遮罩。否则删到一半按一下 ⌫
        // 又去标记一张，状态全乱。
        // **Esc / ⏎ 必须放行**（返回 false 不吞）：结果单上「关闭」「重试」两个按钮
        // 靠 `.keyboardShortcut(.cancelAction / .defaultAction)` 接，这里吞掉就全废了。
        if purgeProgress != nil || purgeReport != nil {
            switch event.keyCode {
            case 53, 36, 76: return false
            default: return true
            }
        }

        let shift = event.modifierFlags.contains(.shift)
        let command = event.modifierFlags.contains(.command)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if command, chars == "a" { selectAll(); return true }

        // 预览开着：只认预览那几个键，别的都不管
        if previewID != nil {
            switch event.keyCode {
            case 51, 117:                       // ⌫ / ⌦：标记 ↔ 取消标记，原地不动
                if let id = previewID, pendingDeletions.contains(id) {
                    unmarkCurrentPreview()
                } else {
                    trashCurrentPreview()
                }
                return true
            case 36, 76:                        // ⏎：选中 ↔ 取消选中
                togglePreviewSelection()
                return true
            case 49:                            // 空格：关
                closePreview()
                return true
            case 123: stepPreview(-1); return true
            case 124: stepPreview(1); return true
            case 53:                            // Esc
                closePreview()
                return true
            default: break
            }
            if chars == "s" { togglePreviewSelection(); return true }
            return false
        }

        switch event.keyCode {
        case 123: move(dx: -1, extend: shift); return true
        case 124: move(dx: 1, extend: shift); return true
        case 126: move(dy: -1, extend: shift); return true
        case 125: move(dy: 1, extend: shift); return true
        case 49, 36, 76: openPreview(); return true
        case 53: clearSelection(); return true
        default: return false
        }
    }
}

// MARK: - 时间分组（按年 / 月 / 日）

extension AppStore {
    enum DateGrouping: String, CaseIterable, Identifiable {
        case day, month, year
        var id: String { rawValue }
        var label: String {
            switch self {
            case .day: return "日"
            case .month: return "月"
            case .year: return "年"
            }
        }
    }

    /// 只有按时间排序时才分小标题；按大小/名称排就没意义了
    var showsDateSections: Bool { sortKey == .date }

    /// 时间轴分组，标题形如「2026年10月31日」「2026年10月」「2026年」
    var assetSections: [(id: String, title: String, assets: [Asset])] {
        let key = "\(visibleSignature)-\(dateGrouping)"
        if key == sectionKey { return sectionCache }
        let built = buildSections()
        sectionCache = built
        sectionKey = key
        return built
    }

    private func buildSections() -> [(id: String, title: String, assets: [Asset])] {
        guard showsDateSections else {
            return [("all", "", visibleAssets)]
        }
        var order: [String] = []
        var buckets: [String: [Asset]] = [:]
        let calendar = Calendar.current
        for asset in visibleAssets {
            let parts = calendar.dateComponents([.year, .month, .day], from: asset.createdAt)
            let key: String
            // 标题不在这里拼：统一由 `bucketTitle(key)` 从 key 反推，少一份重复代码
            switch dateGrouping {
            case .day:
                key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            case .month:
                key = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
            case .year:
                key = String(format: "%04d", parts.year ?? 0)
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(asset)
        }
        return order.map { key in (key, bucketTitle(key), buckets[key] ?? []) }
    }

    private func bucketTitle(_ key: String) -> String {
        let parts = key.split(separator: "-").map { Int($0) ?? 0 }
        switch parts.count {
        case 3: return "\(parts[0])年\(parts[1])月\(parts[2])日"
        case 2: return "\(parts[0])年\(parts[1])月"
        default: return parts.first.map { "\($0)年" } ?? key
        }
    }
}
