# AGENTS.md — cleanmyiphone

macOS 上的 iPhone 空间清理工具（SwiftUI，零外部依赖）。个人项目，不是团队仓库。

## 读取规则

- **动设备通路（PTP / AFC / lockdownd / Photos.sqlite）之前**，先读 `经验文档/设备通路与照片库.md`。
- **动界面、遇闪退、界面乱跳之前**，先读 `经验文档/SwiftUI-版式与崩溃.md`。
- **构建报错、打包、跑探针之前**，先读 `经验文档/构建与调试.md`。
- 判断不了属于哪个领域，就把 `经验文档/` 全读一遍。
- 破坏性操作（删照片、清空回收站、改库）之前必须先读对应文件，禁止凭印象执行。

## 是什么

一个把 iPhone 用数据线连到 Mac 上、按相簿浏览照片/视频、按大小与时间筛选、两步确认后删除、并带标记式回收站的工具。目标：不装 Python、不依赖 Homebrew、单 App 10MB 级。

当前进度：
- 已通：连接、整机统计、照片浏览/筛选/多选、悬停 + 空格预览（图片 + 视频）、两步确认、标记式回收站（**只在内存**）、**相簿二级栏**（本机 18 个相簿）、**11 项筛选**。
- 界面（v6）：**两栏导航 + 右侧设备信息栏**（左 236pt / 右 180pt，右上角收起、⌥⌘I 再打开；全屏预览时两侧自动隐藏）；**应用页与文件页整页删除**（拿不到体积/图标/容器，留着是误导）；概览改为**无饼图**（占比条 + 6 张卡片 + 照片类型 + 相簿大小排行）；照片页把「排序 / 视图」做成显眼的分段控件，删掉类型筛选；相簿栏显示张数 + 体积；照片单击即勾选可累积多选。
- 未做：框选多选、删除流程的真机回归。
- 右侧栏（2026-11 改）：**不再显示电池温度 / 电话号码 / Apple 账户**（三条都拿不到，占位是误导）；新增 激活状态、芯片架构、区域、时区、配对状态、设备状态（锁屏/解锁）、低电量模式、是否插电、健康度分级（优秀/良好/一般/建议维修），设计 vs 有效最大电量、循环次数并列。实现把 `List` 换成 `ScrollView + VStack`：sidebar List 每行暗加约 9pt、行距被顶到 33pt，23 行塞不进默认窗口；现在**行高 18pt、行间 0pt、分节标题上 11 下 3**，默认 720pt 高度一次看全。
- 侧栏计数（2026-11 修）：原来每行各自惰性算 + `@ObservationIgnored` 缓存（`countCache`），视图读缓存后就不再依赖 `libraryIndex`，库到了也不刷新，停在 `0 · 8.93 GB` 直到点一下别处；现在改成 `filterMetrics` 一整包可观察赋值，未就绪统一显示 `LoadingText`（「加载中…」），库读不到显示 `—`。**统计必须遍历 `PhotoLibraryIndex.allMeta`（不去重）**：`metaByFile` 按归一化文件名做键，不同目录同名会互相覆盖，用它统计会少算几百条（实测 5291 → 4942）。
- **筛选（2026-11 定的最终形态）**：侧栏「照片」节 = 全部照片 → **相簿** → 相机 → 照片 → 视频 → 收藏 → 截图 → 实况 → RAW → 已隐藏 → 最近删除。相簿不是筛选项：选「相簿」后**照片页左边挂一条二级栏（相簿列表，不是卡片墙）**，点列表里某个相簿，右边就是那个相簿里的照片和视频；侧栏高亮仍停在「相簿」。进「相簿」时自动选张数最多的那个，不留白页。判据全部来自库：`ZKIND=1` 视频 / `ZKINDSUBTYPE=10` 截图 / `subtype=2 && ZPLAYBACKSTYLE=3` 实况 / `ZADDITIONALASSETATTRIBUTES.ZCAMERACAPTUREDEVICE=1` 相机 / `ZUNIFORMTYPEIDENTIFIER` 含 raw-image 或 .dng 扩展名 = RAW。本机实测 5291 / 397 / 487 / 1935 / 479 / 94。**自拍、电影效果、ProRes 不做**：库里没有可靠判据（自拍没有前置相机标记；电影效果疑似 `ZKINDSUBTYPE=103`、只有 5 条、未与真机核对；ProRes 只能按码率猜），不猜。
- 相簿二级栏要**排除系统占位行**：`ZKIND` 3571/3572/3573（标题 `progress-sync` / `progress-ota-restore` / `progress-fs-import`）和标题以 `progress-` 开头的行，否则二级栏会多出三个 0 张的空相簿（21 → 18）。智能相簿（`FetchingAlbum`，`Z_ENT=40`）没有标题也没有成员，天然被过滤掉。
- 已隐藏 / 最近删除（2026-11 修）：这两个筛选以前从 PTP 的 `assets` 里筛，而 PTP 根本不枚举这两类 → 页面永远空。现在用 `PhotoLibraryIndex.shadowAssets`（库行构造的影子资产，id `lib|<归一化文件名>`）补齐，缩略图走 AFC 取 DCIM 原文件；预览查找也走 `asset(withID:)` 兜到影子资产。
- 电池读数（2026-11 定案）：**健康度/有效最大电量拿不到**。GasGauge 的 `FullChargeCapacity` 是满充百分比不是健康度；IORegistry 每次只回一层 `children`、`regEntry` 为空，按名字点名（AppleSmartBattery / AppleARMPMUCharger / pmu / battery 都试过）也拿不到。界面按"有值才显示"处理，所以这几行不出现，不留 `—`。`batteryNodeProps` 保留但基本拿不到数据，现场写 `battery-dump.txt`。
- 区域：`RegionInfo` 常常是空字典，改为从型号号码尾码推（`MQ0W3CH/A` → CH → 中国大陆）。
- 体积口径：照片/视频用相册库 `ZORIGINALFILESIZE` 求和（本机 8.93 / 47.53 GB）；DCIM 实测 60.49 GB（5950 个文件，15.8 秒）——手机「照片」87.9 GB 还包含衍生与 iCloud 缩略图缓存，那部分第三方拿不到。
- **实测拿不到**（iOS 26.7，别再试）：App 容器（house_arrest 回 `InstallationLookupFailed`）、App 本体体积（`BundleSize`/`Static`/`DynamicDiskUsage` 恒 nil）、App 图标（文件在 `/private/var`）、电池温度、电话号、Apple 账户。详见 `经验文档/设备通路与照片库.md` 第九节。

## 目录

| 路径 | 用途 |
|---|---|
| `Sources/CleanMyiPhone/` | 全部源码（App / Core / Models / UI） |
| `Resources/Info.plist` | App 包信息 |
| `scripts/make-app.sh` | 打包 `.app` + ad-hoc 签名 |
| `Package.swift` / `Makefile` | SwiftPM 与常用命令 |
| `build/` | 产物（`.app`），不提交 |
| `方案讨论.md` / `执行方案.md` / `界面改版讨论.md` / `源码评估与精简.md` / `决策清单.md` | **历史设计稿**（文件头有标记）：看思路可以，别当现状——界面细节已过时，以本文件与源码为准 |
| `经验文档/` | 领域经验，见下 |
| `不推送/` | 本地私人物件，永不提交 |

- 缩略图（2026-11 定案，**已换成「直接读设备端缓存」**）：网格缩略图按这个顺序取，别再往回改：
  1. **`/PhotoData/Thumbnails/V2/<ZDIRECTORY>/<ZFILENAME>/5005.JPG`**（AFC 直读）。这是设备自己维护的缩略图缓存，iMazing 也读这一套（`imazing-reverse/FILESYSTEM.md`）。实测：命中 299/300、**平均 7 ms、平均 65 KB**，照片和视频都有，一张 14–86 KB。`ZDIRECTORY` 自带 `DCIM/109APPLE` 前缀（iCloud 那批是 `PhotoData/PhotoCloudSharingData/...`），**不要再拼一个 `DCIM/`**，否则变成 `V2/DCIM/DCIM/...` 全不命中。找不到 `5005.JPG` 就列一次该资产的目录取最大的 `.JPG`（编号不固定）。
  2. PTP 主动 `requestThumbnailData`（缓存里没有：刚拍、刚导入、iCloud 没落地）。超时按种类：照片 3 秒 / 视频 8 秒；熔断阈值 8 次，**熔断 30 秒后放一次探路请求**（熔断是让开，不是判死刑）。
  3. 只有照片才有第 3 步：AFC 下原图 + ImageIO 降采样。`**不能同时传 imageSourceShouldCache**`，否则尺寸参数被忽略、拿回来是 160×120 糊图。
  以前慢/只出一部分的原因：主路径是"问 PTP"（1.5 秒超时、串行、连续 3 次就熔断），视频只有这条路 → 整屏空；照片兜底又拿 PTP 的 `byteSize` 判完整性 → 明明读完的被判「下载不完整」删掉。两个都改掉了；`loadThumbnail` 的前置 sleep 也从 140 ms 收到 60 ms。
- **asset → 库的匹配有四层**（`AppStore.resolveMeta`）：① 名字一样 ② 数字后缀 + 同扩展名 ③ 体积 + 拍摄时间 ±2 秒 ④ **拍摄时间 ±2 秒 + 同种类**（唯一命中才算）。第 ④ 层是给视频兜底的：PTP 报的视频名常是随机的（`HPQE7329.MP4`），而视频的 PTP `byteSize` 又长期不准 → 第 ③ 层必 miss → 只剩时间可用。实测 396 条视频里 372 条能唯一定位，剩下 24 条是同一秒/相邻秒录的多个视频（有歧义就不猜）。
- **设备端缩略图缓存的覆盖率**（`--probe-videos` 全量审计）：4932 条资产里 **4930 条有缓存**，只有 2 条视频（`IMG_9301.MP4` / `IMG_1771.MOV`）**设备上根本没有这张缩略图**（原片完好，224 MB / 373 MB）。这两条：网格里给「视频占位」（不是空白），PTP 也回不来（SIGTERM 前等 8 秒），所以登记进 `thumbUnavailable` 免得每次滚回来再等一次；点开预览仍可播（走 AFC 原片）。
- **SQLite 是动态类型的（2026-11 修的隐藏 bug）**：`ZDATECREATED` 在同一列里 **2328 行是 integer、2958 行是 real**。`SQLiteDB.Row.double()` 原来只认 `as? Double` → 那 2328 条资产的拍摄时间全变成 `0`（= 2001-01-01）：排序、按时间筛选、"新照片是否让快照过期"、影子资产的日期全跟着错，而界面上看不出来。现在 `int/int64/double` 三种取值都互相兼容。**任何从 Photos.sqlite 取数的列都要按这个前提写**。
- 缩略图日志（`~/Library/Application Support/cleanmyiphone/thumb-log.txt`，最多 4000 行）：`cache-thumb`＝走了设备缓存（最好）、`device-thumb`＝PTP 拿到、`ok(照片)`＝下原图降采样、`fail(照片)`＝失败（`err=` 里的 `lastError` 是共享字段，可能串台，别照字面信）、`drop(不在当前视图)`＝滚过去了。
- 会话（2026-11 修）：**所有开 lockdownd 会话的地方都要 `stopSession`**。`isDeviceLocked()` / `probeAFCOnce()` / `fetchDeviceStats()` / `deviceStatsOffMain()` / `refreshScreen()` 原来都是只 open 不 stop，而这些全在**失败路径**上被反复调用（解锁轮询每 2 秒一次、通道探针每轮一次）→ 设备上漏一串会话，漏够了开始拒连，现象就是「手机的文件通道被系统关掉了」。`DeviceFiles.Session.reset()` 也要真的 `closeAFC` 再置 nil，只置 nil 等于把连接留给了设备。实测并发两条 AFC 这台设备是允许的（两条同时读都没事），所以别把「并发」当元凶，重点是**用完关掉**。
- 预览/下载（2026-11）：优先用**库里的绝对路径** `/DCIM/<ZDIRECTORY>/<ZFILENAME>` 走 AFC（实测 36 MB/s，100 MB ≈ 3 秒）；库还没读到时才退 `ICCameraFile.requestDownload`（PTP 单流小包，几十 MB 的视频会慢到超时）；最后才是名字匹配。进度用设备报的真实大小当分母（PTP 的 `byteSize` 对大视频常偏大，会卡在 90/118 不动）。切目标时上一条下载要**作废并删半截文件**，只有完整文件才进会话缓存（最近 3 个）。
- 取回作废（2026-11 修，原结论从没生效）：`cancelPreviewDownload()` 原来只写在 `if previewID != id` 分支里，而 openPreview / stepPreview / move 都是「先赋 previewID 再调 loadPreviewImage」→ 判断恒不成立，令牌一次都没起效：关掉或换目标后旧视频继续占着串行下载通道跑到收尾，新视频排在它后面干等。现在 `loadPreviewImage` 顶部**无条件**作废，`closePreview()` 也调一次；IC 那条没有自己的取消通路，靠 `isCancelled` 闭包 0.2 秒查一次令牌，过期就 `progressRef.cancel()` 并删半截。
- 进度归属（2026-11 修）：`onProgress` 闭包必须 `guard previewID == id` 再写 `previewBytesDone/Total/ProgressText`，否则旧下载的字节数会一直画在新预览上（"显示的还是上一个视频"就是这么来的）。`waitForLibraryIndex(for:)` 同理，换目标即停止改写阶段文案。
- 完整性判据（2026-11 修）：只有 AFC 的 `st_size` 能当基准（`downloadByDevicePath` 返回 `PathDownload(url, received, planned)`），`planned == 0` 表示这次没可信基准（IC / 名字匹配），**跳过校验**。拿 `previewBytesTotal` 当基准会把"其实已经取完"误报成「取回不完整，再试一次」——PTP 的 `totalUnitCount`/`byteSize` 对大视频长期偏大。
- 预览层播放器（2026-11 修）：`previewVideoURL` 变 nil 时要把 `player` 一起置空；原来 `guard url != nil else { return }` 让旧 `AVPlayer` 留在 `media` 的 `if let player` 分支里，A→B 直接切时屏幕上还是 A 在放。
- 预览卡片（2026-11）：两行——第一行固定阶段（正在读取相册索引 / 正在取回视频 / 正在等待设备通道 / 第一次没取到，重试中），第二行只放字节 `24.6 MB / 118.3 MB`（等宽、固定 300pt），卡片固定 340pt，数字位数变化不抽动。"等待设备响应"那种模糊提示已删；「正在等待设备通道」是 1.5 秒还没收到第一个字节时的兜底，收到数据就换回「正在取回视频」。
- 库门禁（2026-11 定案，已升级成全屏）：照片页在 `libraryIndex == nil` 时**整窗盖死**——遮罩在根视图（`RootView` 的 `.overlay` + `store.needsLibraryGate`），盖住左右两栏和网格，什么都点不了，中间是「正在读取相册索引 + x MB / y MB + 条」。三个例外不盖：暂停态（`dataPaused`，要能点「重新读取」）、未连接（`needsConnection`）、锁屏（`isDeviceLocked`）。`PhotosView` 里那层只留暂停态的「本机数据已清空」卡片，别做成双层。空格预览在库没好时仍然直接 `return`（没有库拿不到设备真实路径）。
- 预览通道（2026-11 修）：`downloadByDevicePath` 走**独立的 AFC 会话 + 独立串行队列**（`previewSession` / `previewQueue`），不再和整屏缩略图挤在 `queue` 上。之前首次进照片页那串缩略图（每个都要在 `downloadLocked` 里 `buildIndex()` 枚举 /DCIM）会把队列顶满，预览排在后面 → 卡片上只有转圈、一个字节都没有，关掉再点别的又正常（因为索引已经建好）。建不起第二条会话时自动回退共用通道，并置 `previewChannelBroken` 不再反复试，`reset()` 清掉该标志。`download(priority: true)` 也走这条通道。
- 取回路径顺序（2026-11 修，实测踩过）：**AFC 绝对路径（库里查得到）→ AFC 名字匹配（/DCIM 索引）→ IC 单流兜底**。原来 IC 排在名字匹配前面，而 PTP 报的名字经常是随机的（实测 `HPQE7329.MP4`，磁盘上是 `IMG_7329.MP4`），`meta(asset)` 查不到就直接掉进 IC → 开头几秒一个字节都没有，卡片显示「正在等待设备通道」。现在 `meta()` 多一层「数字后缀 + 同扩展名」在库里兜（要求唯一命中），查不到也先走 AFC 名字匹配。
- 门禁不会总出现：库在启动阶段就读完时（正常情况，也会打印「库索引就绪（门禁撤）」），进照片页时 `needsLibraryGate` 已经为 false。要验证遮罩得在库读取期间进照片页，或删掉快照重来。
- **性能红线**（2026-11 踩过一次，界面卡死几分钟）：任何「按名字 / 后缀找」的查询都必须走**预建索引**（`PhotoLibraryIndex.fileNameByDigits`），不能在查询里现扫 `metaByFile`。`meta()` 对每张资产都会被调（`tagSet` / `computeVisible` / 侧栏统计），5000 张 × 5000 条字符串过滤 ≈ 2700 万次，全在主线程 → 界面卡死、进度不刷新，表现成「读索引读了 3 分钟」。`AppStore.meta()` 另加一层 `metaCacheStore`，`libraryIndex` 更新时要 `removeAll()`。
- **子进程收尾（2026-11 定案，比"防孤儿"更重要）**：`kill -9` 掉卡在 AFC 调用里的 helper 会把**手机侧 afcd 的通道搞坏**——之后 `--probe-afc` 一律 `连接被关闭`、`--fetch-library` 连 `SIZE` 都打不出来，而 PTP / lockdownd / `isLocked` 全部正常。恢复只能拔插数据线或重启 iPhone。所以退出必须走 `Probe.HelperGuard`：`AFCConnectionInvalidate`（放出阻塞读）→ `AFCConnectionClose` → `AMDeviceStopSession` → `_exit`。触发点三条：`SIGTERM/SIGINT`、**父进程死亡**（父进程拿一根永不打字的管道当子进程 stdin，父进程一死子进程 `read(0,…)` 得 EOF）、正常读完的 `defer`。`getppid()==1` 只在 `report()` 里，卡在第一个 AFC 调用上永远轮不到。父进程侧 `stopHelper`：`terminate()` → 等 2.5 秒 → 才 `SIGKILL`；`killStrayHelpers` 也是先 SIGTERM、**等满 2.5 秒**（用 `pkill -0` 轮询确认真退了）才 `-9`。**看门狗 30 秒**（原来 15 秒太急：设备刚枚举完，AFC 首个回包常要 10 秒以上，一急就 SIGTERM 一个正卡在 AFC 调用里的子进程），总时限 90 秒，296 MB 实测 8–10 秒。
- **完整性与"读了一半当成功"（2026-11 修，这是"数据都不对"的元凶）**：helper 的 `CHECK > 0` 只证明「拿到的这份主库 + WAL 自洽」，证明不了「和刚才量到的 `SIZE` 一致」。AFC 半死时每个文件都会「成功地」只读回一部分，只要主库上次 checkpoint 之前的内容还在，`quick_check` 就过、`ZASSET` 也有行 → 旧的、缺了 WAL 里最新照片的库被当成成功快照，视频数和体积全对不上。现在 `OutputPump` 记下 `SIZE`/`PROGRESS` 的终值，`runFetchHelper` 出结果前对账：**少超过 0.5%（或 512 KB）就抛 `ServiceError.incomplete`**，`fetchOnMain` 因此在 copy 之前就 throw，上一份可用快照原地保留。`ServiceError.incomplete` 以前是死代码，现在真的会抛。
- **重抓前必须让出通道**：`retryLibraryOnce` 除了 `stopPTP()` 还要 `releaseDeviceFiles()`（异步调 `DeviceFiles.shared.reset()`，不阻塞主线程）——否则缩略图的 `photoSession` 和预览的 `previewSession` 还攥着两条 AFC，加上 helper 就是三条压在同一根管子上。
- **单实例守卫**：`SingleInstance` 用 `flock` 锁 `~/Library/Application Support/cleanmyiphone/instance.lock`，第二个实例激活已有窗口后退出。命令行连起两次没有 LaunchServices 拦着，两个实例会各开 PTP、各起 helper 抢同一条 AFC，结果就是"库读不出来"。测试用 `CMI_LOCK_PATH=/tmp/x.lock`（沙箱里 `~/Library` 写不进去，`open` 失败会静默放行）。
- **库读取失败必须有 UI 出口**：`needsLibraryGate` 只认 `libraryIndex == nil`，库读挂了它照样成立；`LibraryIndexGate` 以前只有一个转圈，等于永远在"读"。现在 `libraryStatus` 非空就切换成错误态（原因 + 「重新读取」按钮 → `store.retryLibraryNow()`）。失败日志写 `[library] 读取失败：…`。文案要能定性：`.locked`（真锁屏）/`.channelClosed`（AFC 被设备关掉，要拔插线）/`.timeout`（通道正常但没读完），三者由 `LibraryService.afcChannelState()` 4 秒探针区分，别再一律甩「检查是否已解锁」。
- **失败路径上的设备调用必须带超时**（2026-11 踩过）：`isDeviceLocked()`、`fetchDeviceStats()` 都是 `@MainActor` 上的阻塞 C 调用，管子半死时**永不返回** → 主线程冻住，门禁一直转、日志不再出任何行，看着像"读了很久"。现在 `isDeviceLocked()` 全部走 `LibraryService.withDeviceTimeout(4, fallback:)`，`fetchDeviceStats()` 换成 `deviceStatsOffMain()`（6 秒超时、不在主线程等）。
- **自动重试有上限**：连续失败 3 次就停（`libraryFailureCount` / `libraryAutoRetryStopped`）。`retryLibraryOnce` **不再把 `libraryStatus` 清空**——清了门禁会从「读不出来 + 原因 + 按钮」退回转圈态，用户会以为又重新读了一次，而且失败原因也没了。

- **不留痕（2026-11 重做：一张清单管到底，零痕迹）**：要删的东西**只在 `TraceRegistry` 里定义一份**（数据目录固定文件 + `thumbs/` + `$TMPDIR` 两个临时目录 + 系统 savedState + 系统 `.ips` + `/tmp` 调试日志），三个时机都读它，见 `PurgeGuard`：
  | 退出方式 | 谁清 | 清到什么程度 |
  |---|---|---|
  | ⌘Q / 菜单退出 / 点窗口红点 | `applicationWillTerminate` → `AppStore.purgeOnTerminate()` | 全清（**无条件**，没有开关） |
  | `kill <pid>` / Ctrl+C / 关机信号 | SIGTERM/SIGINT/SIGHUP/SIGQUIT handler | 全清 |
  | 崩溃（SIGSEGV/BUS/ABRT/ILL） | handler 只 `unlink`：固定名 + **`registerTrace` 登记过的每个文件** | 现场能删的全删；系统 `.ips` 与空目录留到下次启动 |
  | `kill -9` / 断电 | `bootstrap()` 第一步的 `purgeLocalDataOnDisk()` | 全清 |
  **崩溃那一刻拿不到目录列表**（`readdir` 不是异步信号安全的），所以每写一个文件就 `TraceRegistry.registerTrace(url)`（固定容量 8192 个 C 字符串，存指针再 `+= count`），handler 只做 `remove()`。信号上下文里**不能调 Foundation**，固定名路径在 `install()` 时用 `prepareSignalSafePaths()` 预先 `strdup` 好。
  `CMI_TRACE_DIR` 可以把整棵数据目录挪到临时位置（测试崩溃清场用，不动真数据）。自检：`CleanMyiPhone --trace-selftest`。
  **实测**（2026-11-01，真机）：启动/退出后 `ls -A ~/Library/Application Support/cleanmyiphone` 空、`$TMPDIR` 无残留、`.ips` 29→0、`/tmp` 调试日志无；只留 `~/Library/Preferences/local.cleanmyiphone.plist`（862 B，窗口位置）。SIGSEGV 实测：崩溃前目录里有四件套，崩后目录空。
  **手动清空（`purgeLocalData`）现在连内存一起清**：库索引、相册列表、assets、缩略图、回收站全丢，界面真的空着；点「重新读取」才重新读设备。侧栏不再有「自动清空」勾选框（开关本身就是痕迹，且关掉它等于允许留 296 MB 复印件），改成一行文案「退出即清空 · 本机不留缓存」。
- 区域（2026-11 修）：`RegionInfo` 在不同读数上会**时有时无、且可能是字符串 `CH/A` 而不是字典**，两种形态都要认；`MQ0W3` 这种无尾码的型号只能靠 RegionInfo。
- 锁屏→解锁（2026-11）：锁屏时开 `unlockWatch`，每 2 秒问一次，解锁即自动重读；不再停在「设备已锁屏」。
- **一个相簿里的「张数」必须三处一致**（2026-11 修）：二级栏、网格项数、底栏是三个来源，以前会差几十条。现在：① 相簿视图**按成员名去重**（成员集合本身就是 `Set<String>`，见 `computeVisible` 的 `albumCovered`），一张照片只算一项；② 体积统一走 `totalBytes(of:)`（`meta.resourceBytes`，含编辑版与 Live Photo 视频分量），拿不到才退 PTP 大小。实测「微信」：库里成员 615 条 → 归一化去重 613；PTP 枚举 666（原件/编辑版/同名各来一条）→ 去重后 613；体积 877.9 MB ↔ 底栏 878 MB。
- **读取中只有一张遮罩**（2026-11 修）：以前「根视图」和「照片页」各有一套（一套是转圈 + 一行字，一套是标题 + 字节 + 进度条），同一个动作两处长得不同。现在统一 `LibraryIndexGate`，三行固定：`正在读取相册索引` / `正在读取 <文件名>` / `已读 x / y`，**总量还没到就显示「已读 x MB」+ 进度条不确定态**（原来 `libraryBytesTotal > 0` 之前只有一个空转的圈）。
- **顶栏不许溢出**（2026-11）：搜索 / 排序 / 升/降序 / 日/月/年 / 视图 / 刷新 整块放进 `.horizontal` 的 `ScrollView`，`.frame(minWidth: 260, maxWidth: .infinity, alignment: .trailing)` + `.clipped()`：窗口窄了就在自己这块里横向滚，绝不压到左边栏上。顶栏**不放标题**（相簿名/类型名都不放，窗口一窄会被挤成竖排两个字）。
- 三栏宽度（2026-11）：左栏 236、相簿二级栏 190、右栏 180 全部 **min = ideal = max**（定宽，不许被挤扁或裁字），中间内容区 `minWidth: 260`（只保证两列），窗口最小 900 —— 236+190+180+260+4 = 870 < 900，所以任何窗口尺寸下三栏都完整、图片不被裁（列数 2/3/4/5 自适应，单格最小 118pt）。改宽度时这四个数要一起算。
- 侧栏底部（2026-11 改）：读取结束后才出现「退出即清空 · 本机不留缓存」+ 两个原生按钮（清空本机数据 / 重新读取），读取过程中整块不显示；按钮下方一行小字报结果或残留项。**没有「自动清空」勾选框了**（见上）。
- **不做快照（2026-11 定）**：那个 6 小时复用的 `loadCachedIndex` 已删除。四件套（`Photos.sqlite` + `-wal` + `-shm` + `thumbnailConfiguration`，约 296 MB）只当**中转**：`LibraryService.fetchOnMain` 读完索引立刻 `purgeSnapshotFiles()` 删掉，失败路径也删。代价是每次启动重读一遍（8–10 秒，后台读、界面照常用）。原来那个 6 小时缓存**其实从来没命中过**——启动第一步就把文件删了。
- **"快照过期"的判据**：设备上最新资产的时间比快照里最新那条**新 2 分钟以上** → 本次运行后台重抓一次（`didAutoRefreshLibrary` 保证每次运行只一次）。这就是"我刚拍两张照片能不能识别出来"的答案：**能**，一拍到 PTP 就枚举出来了，重抓只是把索引补齐（照片时间戳一定比快照里最新那条新）。原来的灾难不是判据错，而是**残缺快照**让它永远为真 —— 那个根因已经由下面那条完整性对账堵住了。
- **没库就别出数**：`mediaPhotoBytes` / `mediaVideoBytes` 在 `libraryIndex` 为空时会退化成「PTP 枚举到的部分资产求和」，而 `appsBytes = 已用 − 媒体 − 系统 − 回收站` —— 视频一小，应用与数据就虚高一大截，用户看到的就是「数据都不对」。现在界面统一看 `mediaBytesReady`（= 库索引非空）：概览三张卡片、占比条、右侧栏「照片/视频」在没就绪时显示「读取中…」/「—」，只保留设备自己报的容量/可用/系统。
- 缩略图缓存：同目录 `thumbs/`（480px JPEG）。里面含文件名、拍摄时间、GPS、相簿名、隐藏/删除标记，以及照片缩小副本 —— 属于真实隐私数据。现在**每写一张就 `registerTrace` 登记**，退出/崩溃/下次启动三处都删。
- 一次性落盘（原图/原视频）：`$TMPDIR/cleanmyiphone-raw/`、`$TMPDIR/cleanmyiphone-preview/`、`$TMPDIR/cleanmyiphone-raw/preview/`。缩略图生成时把整份原图写进来、解完立刻删；预览视频按「最近 3 个」缓存，关预览时清。`cleanmyiphone-preview` 以前是 **0755 目录 + 0644 文件**（同机其他账户能读走整份原视频，实测盘上躺着 660 MB），现在走 `makePrivateDirectory`（0700）。退出/启动仍由 `TraceRegistry.purgeAll()` 整个删掉。
- 目录权限统一 0700（`makePrivateDirectory`）。默认 0755 会被同机其他账户读到。
- 调试日志：`/tmp/cmi-app.log`、`/tmp/cmi-library.log`、`/tmp/cmi-helper-err.log`、`/tmp/cmi-crash.txt`（都要 `CMI_DEBUG=1` / `CMI_TRACE_CRASH=1`）。这四个也在 `TraceRegistry.absoluteFileNames` 里，退出即删。
- 电池诊断：`<数据目录>/battery-dump.txt`（另有 `device-dump.txt` 记 ModelNumber/RegionInfo 实际值）（每次读设备信息都写；不含照片数据，但**按零痕迹一并删**，要排查用 `CMI_DEBUG=1` 重新生成）。

## 经验索引

**设备通路与照片库.md**
- 什么时候读：接设备、读 `Photos.sqlite`、判断某字段能不能拿到、排查"读到 0 条/数量对不上"、改缩略图/预览的取数逻辑。
- 包含什么：usbmuxd 已不可用的结论、MobileDevice 私有框架签名与五个坑、lockdownd 键名表（含真实可用空间键）、照片库表结构与相簿关联表探测、跨通路匹配策略、明确拿不到的四类数据（含电池健康度/温度为什么不行）、删除通道结论；**第八节：相册库 WAL 四件套快照**（整搬 main/wal/shm、不能用 seek 判大小、0 字节读要重试、PTP 会占设备、下载放子进程）；**8.1 读库卡几分钟的三个原因**、**8.2 收尾三步 + 单实例**、**8.3「数据不对 / 缩略图只出一部分 / 通道被关掉」三个独立毛病**（含 `thumb-log.txt` 行义表、完整性对账口径、AFC 好坏的两条探针）、**8.4 设备端缩略图缓存 `/PhotoData/Thumbnails/V2`**、**8.5 四层退出清场**、**8.6 视频缩略图/匹配四层**、**8.7 SQLite 列类型不固定的坑**；**第九节**：iOS 26.7 实测（house_arrest 全关、GasGauge 只有 4 个键、AFC 根目录清单、App 清单、会话泄漏、设备端缩略图怎么做、按库路径取原文件）。
- 不用读：只改界面版式时。

**SwiftUI-版式与崩溃.md**
- 什么时候读：改界面、加图表、改侧栏、遇闪退或布局乱跳、写悬停/键盘交互、写加载态。
- 包含什么：四个直接崩溃的坑（`@State`+`@Observable`、焦点环、`VideoPlayer` 反解崩溃、列数回写）、加载中布局乱跳的根治、读取态只报字节不报百分比、**悬停与键盘焦点**（别用 scaleEffect、离开不清 hoveredID、点完格子要把焦点抢回来、预览层要不透明）、**别在 body 里做 IO / 别在 view update 期间改被观察的集合**、环形绘制与悬停手感、对齐与自适应习惯、图与卡片联动。
- 不用读：只调数据层时。

**构建与调试.md**
- 什么时候读：编译失败、要打包、要跑真机探针、要清空本地数据、要验零痕迹。
- 包含什么：外置卷 + 沙箱下必须带的构建参数、`make-app.sh`、探针开关与环境变量、`--fetch-library` 子进程、崩溃报告与截图调试习惯；**清空本地数据**（App 内入口 + 命令行 + 沙箱里 rm 会被拒的两种绕法）；**零痕迹验收**（退出后四条命令必须为空、`--trace-selftest` 验崩溃清场、`CMI_TRACE_DIR` 隔离测试）。
- 不用读：日常改业务代码时。

## 文档同步（改完功能顺手做）

- `AGENTS.md` 的「当前进度」写的是**现状**，不是历史；改动如果推翻了某条结论，就地改写，别只在下面追加。
- 每篇 `经验文档/` 开头都有「什么时候读」，新增一节就顺手更新索引描述。
- 判断文档是否过时：拿结论去 grep 源码。例如文档说「缩略图走 AFC 下原图」，就应该能在 `PTPBridge` 里找到对应实现；找不到就是过时了。
- `方案讨论 / 执行方案 / 界面改版讨论 / 源码评估与精简 / 决策清单` 是**历史设计稿**，不必跟进，但新结论不要写进它们。

## 禁止

- 个人文件（AGENTS.md、`经验文档/`、`不推送/`）不进任何团队仓库；本工作区本身就是个人目录，不受影响。
- 不记密码、Key、客户隐私；`不推送/` 永不提交。
- 不把 同类商业工具 之类商业 App 的资源文件搬进本仓库。

## 环境

- macOS 27 / Xcode 27 / Swift 6.4，外置卷 `/Volumes/TUF ESD-T1A Media`。
- 真机：iPhone 14 Pro（iPhone15,2）/ iOS 26.7，USB 连接。
- 构建产物目录必须放 `/tmp`（原因见 `经验文档/构建与调试.md`）。
