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
- 已通：连接、整机统计、照片浏览/筛选/多选、悬停 + 空格预览（图片 + 视频）、两步确认、标记式回收站、**相簿树**（Photos.sqlite 四件套快照，本机 5270 资产 / 21 相簿）。
- 界面（v6）：**两栏导航 + 右侧设备信息栏**（左 236pt / 右 180pt，右上角收起、⌥⌘I 再打开；全屏预览时两侧自动隐藏）；**应用页与文件页整页删除**（拿不到体积/图标/容器，留着是误导）；概览改为**无饼图**（占比条 + 6 张卡片 + 照片类型 + 相簿大小排行）；照片页把「排序 / 视图」做成显眼的分段控件，删掉类型筛选；相簿栏显示张数 + 体积；照片单击即勾选可累积多选。
- 未做：框选多选、删除流程的真机回归。
- 右侧栏（2026-11 改）：**不再显示电池温度 / 电话号码 / Apple 账户**（三条都拿不到，占位是误导）；新增 激活状态、芯片架构、区域、时区、配对状态、设备状态（锁屏/解锁）、低电量模式、是否插电、健康度分级（优秀/良好/一般/建议维修），设计 vs 有效最大电量、循环次数并列。实现把 `List` 换成 `ScrollView + VStack`：sidebar List 每行暗加约 9pt、行距被顶到 33pt，23 行塞不进默认窗口；现在**行高 18pt、行间 0pt、分节标题上 11 下 3**，默认 720pt 高度一次看全。
- 侧栏计数（2026-11 修）：原来每行各自惰性算 + `@ObservationIgnored` 缓存（`countCache`），视图读缓存后就不再依赖 `libraryIndex`，库到了也不刷新，停在 `0 · 8.93 GB` 直到点一下别处；现在改成 `filterMetrics` 一整包可观察赋值（一次遍历算完 7 项），未就绪统一显示 `LoadingText`（「加载中…」），库读不到显示 `—`。
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

- 缩略图（2026-11 定案）：**设备端缩略图**。`ICCameraDeviceDelegate` 里实现 `shouldGetThumbnailOf` + 主动 `requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: 800])`（**不能同时传 imageSourceShouldCache，否则尺寸参数被忽略**，拿回来就是 160×120 的糊图），收到即落 480px JPEG。取不到就跳过，网格里从不下整片视频。流式播放、AVFoundation 抽帧、resource-loader 那几套全部删掉（这台设备上实测不通，白等超时）。
- 预览/下载（2026-11）：优先用**库里的绝对路径** `/DCIM/<ZDIRECTORY>/<ZFILENAME>` 走 AFC（实测 36 MB/s，100 MB ≈ 3 秒）；库还没读到时才退 `ICCameraFile.requestDownload`（PTP 单流小包，几十 MB 的视频会慢到超时）；最后才是名字匹配。进度用设备报的真实大小当分母（PTP 的 `byteSize` 对大视频常偏大，会卡在 90/118 不动）。切目标时上一条下载要**作废并删半截文件**，只有完整文件才进会话缓存（最近 3 个）。
- 预览卡片（2026-11）：两行——第一行固定阶段（正在读取相册索引 / 正在取回视频 / 第一次没取到，重试中），第二行只放字节 `24.6 MB / 118.3 MB`（等宽、固定 300pt），卡片固定 340pt，数字位数变化不抽动。"等待设备响应"那种模糊提示已删。
- 库门禁（2026-11）：库索引没读到（`libraryIndex == nil`）时照片页盖一层进度卡（`x MB / y MB` + 进度条），并且**空格预览直接 return**——没有库就拿不到设备真实路径，只能走慢路。
- 不留痕（2026-11 定案）：侧栏底部三件套——`☑ 自动清空本机数据`（控制退出/启动时自动清，默认勾选）、`清空本机数据`（立刻清一次）、`重新读取`（清空后手动重建）。**手动清空之后进入暂停态**（`dataPaused`）：不重扫、不重生成缩略图、不能预览，照片页显示「本机数据已清空」，直到点「重新读取」——这是用户明确要求的行为，别改成清完自动重建。`purgeLocalDataOnDisk()` 会回查剩余项并在按钮下方报出来；回查必须放在 `purgeTransientFiles()` **之前**（后者会把 `thumbs` 目录重新建出来，放后面就永远报没删掉）。
- 区域（2026-11 修）：`RegionInfo` 在不同读数上会**时有时无、且可能是字符串 `CH/A` 而不是字典**，两种形态都要认；`MQ0W3` 这种无尾码的型号只能靠 RegionInfo。
- 锁屏→解锁（2026-11）：锁屏时开 `unlockWatch`，每 2 秒问一次，解锁即自动重读；不再停在「设备已锁屏」。
- 侧栏底部（2026-11）：读取结束后才出现上面那三件套（勾选 + 两个原生 `.bordered`/`.small` 按钮），读取过程中整块不显示；按钮下方一行小字报结果。
- 相册库快照：`~/Library/Application Support/cleanmyiphone/`（`Photos.sqlite` + `-wal` + `-shm` + `thumbnailConfiguration`，约 296 MB），6 小时内复用，设备上有更新照片会自动重抓。删掉即回到「新机」状态。
- 缩略图缓存：同目录 `thumbs/`（480px JPEG）。里面含文件名、拍摄时间、GPS、相簿名、隐藏/删除标记，以及照片缩小副本 —— 属于真实隐私数据，所以「自动清空」勾着时退出即删。
- 一次性落盘（原图/原视频）：`$TMPDIR/cleanmyiphone-raw/`、`$TMPDIR/cleanmyiphone-preview/`、`$TMPDIR/cleanmyiphone-raw/preview/`。缩略图生成时把整份原图写进来、解完立刻删；预览的视频以前会留在本机（实测堆到 1.2 GB）。**现在启动、关预览、退出 App 三处都会清**（`DeviceFiles.purgeTransientFiles`）。
- 目录权限统一 0700（`makePrivateDirectory`）。默认 0755 会被同机其他账户读到。
- 调试日志：`/tmp/cmi-app.log`、`/tmp/cmi-library.log`、`/tmp/cmi-crash.txt`（都要 `CMI_DEBUG=1` / `CMI_TRACE_CRASH=1`）。
- 电池诊断：`~/Library/Application Support/cleanmyiphone/battery-dump.txt`（另有 `device-dump.txt` 记 ModelNumber/RegionInfo 实际值）（每次读设备信息都写，记录 diagnostics_relay 每次 IORegistry 请求回了哪些键、有没有命中电池节点；不含照片数据，退出清空时不动它）。

## 经验索引

**设备通路与照片库.md**
- 什么时候读：接设备、读 `Photos.sqlite`、判断某字段能不能拿到、排查"读到 0 条/数量对不上"、改缩略图/预览的取数逻辑。
- 包含什么：usbmuxd 已不可用的结论、MobileDevice 私有框架签名与五个坑、lockdownd 键名表（含真实可用空间键）、照片库表结构与相簿关联表探测、跨通路匹配策略、明确拿不到的四类数据（含电池健康度/温度为什么不行）、删除通道结论；**第八节：相册库 WAL 四件套快照**（整搬 main/wal/shm、不能用 seek 判大小、0 字节读要重试、PTP 会占设备、下载放子进程）；**第九节**：iOS 26.7 实测（house_arrest 全关、GasGauge 只有 4 个键、AFC 根目录清单、App 清单、会话泄漏、设备端缩略图怎么做、按库路径取原文件）。
- 不用读：只改界面版式时。

**SwiftUI-版式与崩溃.md**
- 什么时候读：改界面、加图表、改侧栏、遇闪退或布局乱跳、写悬停/键盘交互、写加载态。
- 包含什么：四个直接崩溃的坑（`@State`+`@Observable`、焦点环、`VideoPlayer` 反解崩溃、列数回写）、加载中布局乱跳的根治、读取态只报字节不报百分比、**悬停与键盘焦点**（别用 scaleEffect、离开不清 hoveredID、点完格子要把焦点抢回来、预览层要不透明）、**别在 body 里做 IO / 别在 view update 期间改被观察的集合**、环形绘制与悬停手感、对齐与自适应习惯、图与卡片联动。
- 不用读：只调数据层时。

**构建与调试.md**
- 什么时候读：编译失败、要打包、要跑真机探针、要清空本地数据。
- 包含什么：外置卷 + 沙箱下必须带的构建参数、`make-app.sh`、探针开关与环境变量、`--fetch-library` 子进程、崩溃报告与截图调试习惯；**清空本地数据**（App 内入口 + 命令行 + 沙箱里 rm 会被拒的两种绕法 + 「回查必须在 purgeTransientFiles 之前」这个坑）。
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
