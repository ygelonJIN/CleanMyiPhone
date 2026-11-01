import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppStore {

    // MARK: - 导航

    enum Section: String, Identifiable {
        case overview, photos, trash
        var id: String { rawValue }
    }

    /// 侧边栏的一行。侧栏选中项就是唯一真相：section / 筛选都从这里推出来，
    /// 不会再出现「侧栏选中 A、内容显示 B」的错位。
    enum SidebarItem: Hashable {
        case overview
        case photos(LibraryFilter)
        case album(Int)
        case trash
    }

    var sidebarItem: SidebarItem = .overview

    var section: Section {
        switch sidebarItem {
        case .overview: return .overview
        case .photos, .album: return .photos
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
    var screenImage: NSImage?
    var stats = LibraryService.DeviceStats()

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
    var confirmPresented = false
    var confirmStage = 0
    var isPurging = false
    var purgeMessage: String?

    var columns = 6
    var previewID: Asset.ID?
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
    private var forceLibraryRefresh = false
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
        resetScan(skipLibrary: false)
        applyDebugStartSection()
        // 启动先清一遍：覆盖「上次被强杀 / Cmd+Q 没走完」的情况
        if autoPurge {
            purgeLeftovers = Self.purgeLocalDataOnDisk()
        } else {
            DeviceFiles.purgeTransientFiles()
        }

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
        guard let raw = ProcessInfo.processInfo.environment["CMI_START_SECTION"]?.lowercased() else { return }
        switch raw {
        case "trash": sidebarItem = .trash
        case "photos": sidebarItem = .photos(.all)
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

    func startScan() async {
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
        resetScan(skipLibrary: libraryDone)
        forceLibraryRefresh = true
        if !libraryDone { libraryStatus = nil }
        stopPTP()
        startPTP()
    }

    private func beginSession() {
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

        // 本地已有新鲜快照就直接用，别再搬一次 296MB
        if !forceLibraryRefresh, let cached = LibraryService.loadCachedIndex() {
            libraryIndex = cached
            libraryAlbums = cached.albumsSorted()
            invalidateCounts()
            libraryDone = true
            libraryFraction = 1
            libraryStatus = nil
            if let snapshot = try? await LibraryService.fetchDeviceStats() {
                applyStats(snapshot)
            }
            recomputeProgress()
            maybeFinishScan()
            return
        }
        forceLibraryRefresh = false

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
            libraryAlbums = snapshot.index.albumsSorted()
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
            libraryDone = true
            libraryFraction = 1
            rebuildMetrics()
            libraryStatus = error.localizedDescription
            if let service = error as? LibraryService.ServiceError, case .locked = service {
                isDeviceLocked = true
                // 锁屏时什么都读不到。开一个探针盯着，一解锁就自动重读，
                // 不用让用户自己回来点刷新（之前解锁了界面还停在"设备已锁屏"）。
                startUnlockWatch()
                recomputeProgress()
                maybeFinishScan()
                return
            }
            // 相册库读不到也要拿到容量/型号，概览才有内容
            if stats.totalCapacity == 0 {
                if let fallback = try? await LibraryService.fetchDeviceStats() {
                    applyStats(fallback)
                }
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
                let unlocked = await Task.detached { !LibraryService.isDeviceLocked() }.value
                guard unlocked else { continue }
                await MainActor.run {
                    self.isDeviceLocked = false
                    self.unlockWatch = nil
                }
                await self.startScan()
                return
            }
        }
    }

    /// 设备上出现了比本地快照更新的照片 → 相册库快照过期
    private func libraryLooksStale() -> Bool {
        guard libraryIndex != nil, !usingFixture else { return false }
        guard let newestDevice = assets.map(\.createdAt).max() else { return false }
        let newestSnapshot = libraryIndex?.metaByFile.values.map(\.createdAt).max() ?? .distantPast
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

    private func retryLibraryOnce(force: Bool = false) async {
        guard !usingFixture else { return }
        if !force, libraryIndex != nil { return }
        forceLibraryRefresh = true
        // 重试时临时让出设备：有 ICCamera 会话时子进程的 AFC 会打不开文件
        let pausePTP = ptpWired
        if pausePTP { stopPTP() }
        try? await Task.sleep(nanoseconds: 800_000_000)

        libraryStarted = false
        libraryDone = false
        libraryFraction = 0
        libraryStatus = nil
        await loadLibrary()

        if pausePTP { startPTP() }
        maybeFinishScan()
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
        for meta in index.metaByFile.values {
            let bytes = meta.resourceBytes
            if meta.isVideo { videos.count += 1; videos.bytes += bytes }
            else { photos.count += 1; photos.bytes += bytes }
            if meta.isFavorite { favorites.count += 1; favorites.bytes += bytes }
            if meta.isHidden { hidden.count += 1; hidden.bytes += bytes }
            if meta.isTrashed { trashed.count += 1; trashed.bytes += bytes }
            if meta.subtype == 10 { shots.count += 1; shots.bytes += bytes }
        }
        let all = FilterMetric(count: photos.count + videos.count, bytes: photos.bytes + videos.bytes)
        filterMetrics = [.all: all, .photos: photos, .videos: videos,
                         .favorites: favorites, .screenshots: shots,
                         .hidden: hidden, .trashed: trashed]
        metricsReady = true
        metricsLibraryUnavailable = false
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

    /// 照片类型三行：相机拍摄 / 截屏 / 视频（互斥，合计等于媒体总量）
    struct PhotoKindRow {
        let title: String
        let count: Int
        let bytes: Int64
        let percent: Double
        let color: Color
    }

    var photoKindRows: [PhotoKindRow] {
        let shots = screenshotAssets
        let shotBytes = sum(shots)
        let photoOnly = max(0, mediaPhotoBytes - shotBytes)
        let videos = mediaVideoBytes
        let total = max(photoOnly + shotBytes + videos, 1)
        return [
            .init(title: "相机拍摄",
                  count: max(0, libraryPhotoCount - shots.count),
                  bytes: photoOnly, percent: Double(photoOnly) / Double(total) * 100,
                  color: Theme.photo),
            .init(title: "截屏", count: shots.count,
                  bytes: shotBytes, percent: Double(shotBytes) / Double(total) * 100,
                  color: Theme.screenshot),
            .init(title: "视频",
                  count: libraryVideoCount,
                  bytes: videos, percent: Double(videos) / Double(total) * 100,
                  color: Theme.video)
        ]
    }

    struct Slice: Identifiable {
        let id = UUID()
        let title: String
        let bytes: Int64
        let color: Color
    }





    // MARK: - 饼图数据（概览与应用页共用同一套口径）

    /// 截图（相机截图，subtype 10 或 PTP 标签）
    private var screenshotAssets: [Asset] {
        assets.filter { tagSet($0).contains(.screenshot) }
    }

    private func sum(_ list: [Asset]) -> Int64 { list.reduce(0) { $0 + $1.byteSize } }


    /// 通用「某一类 / 其他」两段饼
    



    /// 相簿体积（按体积降序，只留 >0 的）
    

    /// 单个相簿的体积（带缓存，相簿栏和概览都要用）
    @ObservationIgnored private var albumByteCache: [Int: Int64] = [:]

    func albumBytes(_ albumID: Int) -> Int64 {
        if let cached = albumByteCache[albumID] { return cached }
        guard let index = libraryIndex else { return 0 }
        let files = index.files(inAlbum: albumID)
        var total: Int64 = 0
        if !files.isEmpty {
            for asset in assets {
                let name = metaCache(asset).map { PhotoLibraryIndex.normalize($0.fileName) }
                    ?? PhotoLibraryIndex.normalize(asset.fileName)
                if files.contains(name) { total += asset.byteSize }
            }
        }
        albumByteCache[albumID] = total
        return total
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

    func metaCache(_ asset: Asset) -> PhotoLibraryIndex.Meta? {
        if let cached = metaCacheStore[asset.id] { return cached }
        let value = meta(asset)
        metaCacheStore[asset.id] = value
        return value
    }

    // MARK: - 筛选

    /// 单张资产的真实占用：优先用相册库里的资源合计，退回归一化后的 PTP 大小
    func byteSize(of asset: Asset) -> Int64 {
        if let meta = meta(asset), meta.resourceBytes > 0 { return meta.resourceBytes }
        return asset.byteSize
    }

    func meta(_ asset: Asset) -> PhotoLibraryIndex.Meta? {
        guard let index = libraryIndex else { return nil }
        if let hit = index.meta(for: asset.fileName) { return hit }
        return index.meta(matching: asset.byteSize, date: asset.createdAt)
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
        }
    }

    var currentScopeTitle: String {
        if let albumFilter, let album = libraryAlbums.first(where: { $0.id == albumFilter }) {
            return album.title
        }
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

        var result = assets
        if libraryFilter != .all {
            result = result.filter { matches($0, filter: libraryFilter) }
        }
        if let albumFilter, let index = libraryIndex {
            let files = index.files(inAlbum: albumFilter)
            result = result.filter { asset in
                if let meta = meta(asset) {
                    return files.contains(PhotoLibraryIndex.normalize(meta.fileName))
                }
                return files.contains(PhotoLibraryIndex.normalize(asset.fileName))
            }
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
                    if claimed.contains(key) { continue }
                    guard let meta = index.meta(for: shadow.fileName) else { continue }
                    switch libraryFilter {
                    case .hidden where !meta.isHidden: continue
                    case .trashed where !meta.isTrashed: continue
                    case .favorites where !meta.isFavorite: continue
                    case .screenshots where meta.subtype != 10: continue
                    default: break
                    }
                    if let albumFiles, !albumFiles.contains(key) { continue }
                    result.append(shadow)
                }
            }
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
        case .name: result.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        }
        if !ascending { result.reverse() }
        return result
    }

    var visibleBytes: Int64 { visibleAssets.reduce(0) { $0 + $1.byteSize } }
    var selectedAssets: [Asset] { visibleAssets.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedAssets.reduce(0) { $0 + $1.byteSize } }
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
        selection = Set(list[range].map(\.id))
    }

    func selectAll() { selection = Set(visibleAssets.map(\.id)) }

    func clearSelection() {
        selection = []
        anchorID = nil
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

    // MARK: - 待删 / 回收站

    /// 预览里点按钮删除当前这一项
    func trashCurrentPreview() {
        guard let id = previewID, let asset = assets.first(where: { $0.id == id }) else { return }
        trash.add([asset], deviceID: device?.id ?? "unknown")
        selection.remove(id)
        stepPreview(1)
    }

    /// 预览里切换「当前这一项」的选中状态
    func togglePreviewSelection() {
        guard let id = previewID else { return }
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
            anchorID = id
        }
    }

    func presentDeleteConfirm() {
        guard !selection.isEmpty else { return }
        confirmStage = 1
        confirmPresented = true
    }

    func confirmDelete() {
        let chosen = selectedAssets
        guard !chosen.isEmpty else {
            confirmPresented = false
            return
        }
        trash.add(chosen, deviceID: device?.id ?? "unknown")
        clearSelection()
        confirmPresented = false
        confirmStage = 1
    }

    func restoreFromTrash(ids: [Asset.ID]) {
        trash.remove(ids: ids)
    }

    func emptyTrash() async {
        let entries = trash.entries
        guard !entries.isEmpty, !isPurging else { return }
        isPurging = true
        defer { isPurging = false }

        let engine = PurgeEngine(trash: trash, source: { [self] in source })
        let outcome = await engine.purge(entries)

        let removed = Set(outcome.succeeded)
        assets.removeAll { removed.contains($0.id) }
        invalidateCounts()
        thumbnails = thumbnails.filter { !removed.contains($0.key) }

        if outcome.failed.isEmpty {
            purgeMessage = "已释放 \(ByteCountFormatter.string(fromByteCount: outcome.succeededBytes, countStyle: .file))"
        } else {
            let first = outcome.failed.first?.message ?? "未知原因"
            purgeMessage = "\(outcome.summary)，\(first)"
        }
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
        previewID = target
        loadPreviewImage(for: target)
    }

    func closePreview() {
        previewID = nil
        previewImage = nil
        previewVideoURL = nil
        previewLoading = false
        previewProgressText = ""
        previewError = nil
        // 不再这里删文件：播放器可能还拿着它，删了就是"播放不可用"。
        // 预览副本仍然会在**退出 App / 下次启动**时统一清掉（purgeTransientFiles），
        // 会话内最多留最近 3 个视频。
        DeviceFiles.emptyDirectory(DeviceFiles.rawCacheDirectory.appendingPathComponent("preview",
                                                                                     isDirectory: true))
    }

    func stepPreview(_ delta: Int) {
        let list = visibleAssets
        guard let previewID, let index = list.firstIndex(where: { $0.id == previewID }) else { return }
        let next = min(max(0, index + delta), list.count - 1)
        self.previewID = list[next].id
        anchorID = list[next].id
        loadPreviewImage(for: list[next].id)
    }

    /// 本次会话里已经取回的视频文件：反复空格开关同一个视频不再重下，
    /// 也不会出现"取完就被删、播放器拿着失效路径 → 播放不可用"。
    @ObservationIgnored private var previewFileCache: [Asset.ID: URL] = [:]
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cleanmyiphone-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func loadPreviewImage(for id: Asset.ID) {
        // 预览是用户主动操作，优先给它带宽：把还没开始的缩略图请求全丢掉
        pendingThumbs.removeAll()
        DeviceFiles.shared.cancelPending()
        // 换到另一个视频时，把上一次还没下完的作废 ——
        // 否则新视频会排在旧视频后面取，看起来像"打开了却没反应"。
        if previewID != id {
            DeviceFiles.shared.cancelPreviewDownload()
            previewBytesDone = 0
            previewBytesTotal = 0
        }
        if libraryIndex == nil, !usingFixture {
            previewProgressText = "" 
        }
        // 先用网格里已有的 480px 立刻显示，再后台换大图，切换不空屏
        previewImage = thumbnails[id]
        previewVideoURL = nil
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
            Task {
                self.previewStageText = "正在取回视频"
                var url: URL?
                for attempt in 0..<2 {
                    url = await self.downloadOriginal(for: asset, to: Self.previewDirectory) { done, total in
                        Task { @MainActor in
                            self.previewBytesDone = done
                            self.previewBytesTotal = total
                            // 报字节，不报百分比：进度条骗人的时候，字节数是实打实的
                            self.previewProgressText = total > 0
                                ? "\(Self.sizeText(done)) / \(Self.sizeText(total))"
                                : Self.sizeText(done)
                        }
                    }
                    if url != nil { break }
                    if attempt == 0, self.previewID == id {
                        previewStageText = "第一次没取到，重试中"
                    }
                }
                if self.previewID != id { return }
                self.previewLoading = false
                if let url {
                    // 只有完整文件才进缓存：半截文件留在缓存里 = 下次"播放失败"
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
                    // 用设备报的字节数当基准（PTP 的 byteSize 对大视频常偏大，不能拿来校验）
                    let expected = self.previewBytesTotal
                    if expected > 0, size > 0, size < expected {
                        try? FileManager.default.removeItem(at: url)
                        self.previewLoading = false
                        self.previewError = "取回不完整，再试一次"
                        return
                    }
                    self.rememberPreviewFile(url, for: id)
                    self.previewVideoURL = url
                } else {
                    self.previewError = DeviceFiles.shared.lastError ?? "取不回来"
                }
            }
        } else {
            // 已有小图就先把 loading 关掉；大图在后台换
            previewLoading = previewImage == nil
            previewError = nil
            Task {
                // 预览要原图：整份下载 → 原生尺寸解码，不降采样、不重编码。
                var cg: CGImage?
                if let url = await self.downloadOriginal(for: asset,
                                                         to: DeviceFiles.previewPhotoDirectory),
                   let decoded = DeviceFiles.decodeOriginal(url, asset: asset) {
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
                if cg == nil { self.previewError = "取不到这张图（设备没回数据）" }
            }
        }
    }

    /// 取原始文件：优先用 ImageCaptureCore 自己的下载接口。
    /// AFC 那条路要靠文件名去 /DCIM 索引里匹配，PTP 名字和磁盘名字对不上时就报
    /// 「DCIM 里找不到」；IC 是按设备对象句柄取的，不存在这个问题。
    /// 预览取原文件前，等相册库索引就绪（最多 10 秒）。
    /// 库里有 `ZDIRECTORY`/`ZFILENAME` 才能走 AFC 的 36 MB/s；
    /// 库没到就只能退回 IC 的单流下载，几百 MB 的视频会慢到超时。
    private func waitForLibraryIndex(maxSeconds: Double = 20) async {
        guard libraryIndex == nil, !usingFixture else { return }
        let deadline = Date().addingTimeInterval(maxSeconds)
        while libraryIndex == nil, Date() < deadline {
            // 让用户看到"在等什么"：库索引读到哪了
            previewStageText = "正在读取相册索引"
            previewProgressText = libraryBytesTotal > 0
                ? "\(Self.sizeText(libraryBytesDone)) / \(Self.sizeText(libraryBytesTotal))"
                : ""
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func downloadOriginal(for asset: Asset,
                                  to directory: URL,
                                  onProgress: ((Int64, Int64) -> Void)? = nil) async -> URL? {
        await waitForLibraryIndex()
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
            if let url = await DeviceFiles.shared.downloadByDevicePath(paths, to: directory,
                                                                      expected: asset.byteSize,
                                                                      onProgress: onProgress) {
                return url
            }
        }
        // 2) 库还没读到时：IC 按对象句柄下载
        if let ptp = source as? PTPBridge,
           let url = await ptp.downloadOriginal(for: asset, to: directory, onProgress: onProgress) {
            return url
        }
        // 3) 最后才是名字匹配
        return await DeviceFiles.shared.download(fileName: asset.fileName,
                                                 libraryName: meta(asset)?.fileName,
                                                 to: directory)
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

    func thumbTrace(_ text: String) {
        guard thumbLogWrites < 4000 else { return }
        thumbLogWrites += 1
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cleanmyiphone", isDirectory: true)
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
        // 滚动时快速掠过格子：等一小会儿再下，格子被回收就不为它拉原文件
        try? await Task.sleep(nanoseconds: 140_000_000)
        if Task.isCancelled { return }

        // 切排序 / 换相簿 / 换筛选之后，上一屏的排队请求就不再需要了
        let stillWanted = await MainActor.run { isThumbnailWanted(asset.id) }
        guard stillWanted else {
            thumbTrace("drop(不在当前视图) \(asset.fileName)")
            return
        }

        // 1) 设备端缩略图（照片和视频都有，实现 shouldGetThumbnailOf 之后才有）
        if let image = await source.thumbnail(for: asset, maxPixel: 480) {
            await MainActor.run {
                thumbTrace("device-thumb \(asset.fileName)")
                storeThumbnail(asset.id, image)
            }
            return
        }

        // 2) 视频：设备端缩略图没给就跳过。
        //    网格里下整片（一屏几 GB）不现实，抽帧那套已经删掉了。
        if asset.kind == .video { return }

        // 3) 照片：AFC 下原图 + 降采样
        let data = await DeviceFiles.shared.thumbnailData(for: asset,
                                                          libraryName: meta(asset)?.fileName,
                                                          maxPixel: 480)
        await MainActor.run {
            // NSImage 一律在主线程创建，后台创建的拿到这里渲染是黑图
            if let data, let image = NSImage(data: data) {
                thumbTrace("ok(照片) \(asset.fileName) \(data.count)B")
                storeThumbnail(asset.id, image)
            } else {
                thumbTrace("fail(照片) \(asset.fileName) err=\(DeviceFiles.shared.lastError ?? "-")")
            }
        }
    }

    // MARK: - 不留痕模式（退出即清空）

    private static let autoPurgeKey = "cmi.autoPurge"

    /// 自动清空（退出 / 启动时）。默认开。手动「清空本机数据」不受这个开关影响。
    var autoPurge: Bool = (UserDefaults.standard.object(forKey: "cmi.autoPurge") as? Bool) ?? true

    func setAutoPurge(_ on: Bool) {
        autoPurge = on
        UserDefaults.standard.set(on, forKey: Self.autoPurgeKey)
    }

    /// 手动清空之后**暂停一切重建**：不重扫、不重生成缩略图。
    /// 想继续用就点「重新读取」（这是用户明确要求的：清空就该真的空着）。
    private(set) var dataPaused = false

    /// 删掉所有落盘的设备数据：缩略图、相册库四件套、一次性原图/原视频。
    /// 返回**没删掉的**条目 —— 删不动要能看见，不能让界面假装"已清空"。
    @discardableResult
    static func purgeLocalDataOnDisk() -> [String] {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cleanmyiphone", isDirectory: true)
        // thumb-log.txt 里是照片文件名，属于痕迹，一并删掉；
        // battery-dump / device-dump 只有机型和键名，留着方便排查。
        let names = ["thumbs", "Photos.sqlite", "Photos.sqlite-wal",
                     "Photos.sqlite-shm", "thumbnailConfiguration", "thumb-log.txt"]
        for name in names {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
        // 先回查：purgeTransientFiles 会把缓存根目录（含 thumbs）重新建出来，
        // 放在它后面查，就会永远报「thumbs 没删掉」。
        let leftovers = names.filter { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        DeviceFiles.purgeTransientFiles()
        return leftovers
    }

    /// 上次清空有没有漏：界面要如实显示
    private(set) var purgeLeftovers: [String] = []

    /// 退出回调里拿不到 store 实例，用这个静态入口；勾了「自动清空」才清。
    static func purgeOnTerminate() {
        let on = (UserDefaults.standard.object(forKey: autoPurgeKey) as? Bool) ?? true
        guard on else { return }
        purgeLocalDataOnDisk()
    }

    /// 立即清空磁盘数据。
    /// **只删磁盘，不动内存里已经解析好的库索引**：内存不是痕迹，
    /// 清掉它反而让侧栏计数掉回「加载中」，看起来像清空了数据。
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
        // 清完就停在这：不重扫、不重生成缩略图，等用户点「重新读取」
        dataPaused = true
        previewError = nil
        purgeMessage = purgeLeftovers.isEmpty ? "已清空，点「重新读取」可重新建立"
            : "有 \(purgeLeftovers.count) 项没删掉：\(purgeLeftovers.joined(separator: "、"))"
    }

    /// 手动恢复：解除暂停并重新读取设备
    func resumeReading() {
        guard dataPaused else { return }
        dataPaused = false
        purgeMessage = nil
        bumpThumbEpoch()
        if libraryIndex == nil {
            Task { await startScan() }
        }
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

    static let handledKeys: Set<KeyEquivalent> = [
        .upArrow, .downArrow, .leftArrow, .rightArrow,
        .space, .delete, .return, .escape,
        KeyEquivalent("a"), KeyEquivalent("A"),
        KeyEquivalent("s"), KeyEquivalent("S")
    ]

    @discardableResult
    func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        let command = press.modifiers.contains(.command)

        if previewID != nil {
            switch press.key {
            case .leftArrow: stepPreview(-1); return .handled
            case .rightArrow: stepPreview(1); return .handled
            case .space:
                // 预览开着时空格就是「关」，鼠标停在哪不再影响结果
                closePreview()
                return .handled
            case .delete:
                // 预览里直接打删除标记，不关预览
                togglePreviewSelection()
                trashCurrentPreview()
                return .handled
            case KeyEquivalent("s"), KeyEquivalent("S"):
                // 预览里也能选中 / 取消选中，再切下一张继续选
                togglePreviewSelection()
                stepPreview(1)
                return .handled
            case .return:
                togglePreviewSelection()
                return .handled
            case .escape: closePreview(); return .handled
            default: break
            }
        }

        switch press.key {
        case .leftArrow: move(dx: -1, extend: shift); return .handled
        case .rightArrow: move(dx: 1, extend: shift); return .handled
        case .upArrow: move(dy: -1, extend: shift); return .handled
        case .downArrow: move(dy: 1, extend: shift); return .handled
        case .space, .return: openPreview(); return .handled
        case .delete:
            return .ignored
        case .escape:
            if previewID != nil { closePreview() } else { clearSelection() }
            return .handled
        case KeyEquivalent("a"), KeyEquivalent("A"):
            if command { selectAll(); return .handled }
            return .ignored
        default:
            return .ignored
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
            let title: String
            switch dateGrouping {
            case .day:
                key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
                title = "\(parts.year ?? 0)年\(parts.month ?? 0)月\(parts.day ?? 0)日"
            case .month:
                key = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
                title = "\(parts.year ?? 0)年\(parts.month ?? 0)月"
            case .year:
                key = String(format: "%04d", parts.year ?? 0)
                title = "\(parts.year ?? 0)年"
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
