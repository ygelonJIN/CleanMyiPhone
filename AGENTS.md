# AGENTS.md — cleanmyiphone

macOS 上的 iPhone 空间清理工具（SwiftUI，零外部依赖）。个人项目，不是团队仓库。

## 桌面操作红线（比什么都优先）

- **不许截图**：不跑 `screencapture`、不装/不用任何截屏工具、不要「截一张图看看版式」。
- **不许操控鼠标键盘**：不点窗口、不激活/抢焦点、不发合成按键（AppleScript / System Events / cliclick / CGEvent 一律不许），也不要为了让截图好看去动别人的 App 或窗口。
- 界面改动的验收只做到：**编译 → 打包 `./scripts/make-app.sh release` → 核验新文案进没进二进制**（`经验文档/构建与调试.md` 第二节）。要看界面、要挪窗口、要开预览，**让用户自己开**——可以用 `CMI_START_SECTION` / `CMI_DEMO_PREVIEW` / `CMI_TRASH_DEMO` 这类启动开关给对方说明怎么复现，但不许由 agent 驱动桌面。
- 需要视觉确认时，把「看哪一页、盯哪一处、窗口拉多窄」写清楚交给用户，别自己上手。

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
- 界面（v6）：**两栏导航 + 右侧设备信息栏**（左 236pt / 右 180pt，右上角收起、⌥⌘I 再打开；预览时两侧**不再自动隐藏**，见下面那条）；**应用页与文件页整页删除**（拿不到体积/图标/容器，留着是误导）；概览改为**无饼图**（占比条 + 6 张卡片 + 照片类型 + 相簿大小排行）；照片页把「排序 / 视图」做成显眼的分段控件，删掉类型筛选；相簿栏显示张数 + 体积；照片单击即勾选可累积多选。
- 界面（2026-11 三轮，用户逐条提的）：**所有顶栏都没有标题、控件组永远居中** —— 概览 / 照片 / 相簿 / 回收站一致，窗口拉宽拉窄都不许往左或往右跑（`PageToolbar`，替代了原来的 `DetailHeader`；概览的「设备名 / 正在读取 / 已锁屏」搬到底栏 38pt）。**升降序改用文字「升序/降序」**（44pt，不再用箭头图标）。顶栏外面那层横向 `ScrollView` **已删除**（宽度算得准，那层兜底才是把右侧刷新按钮裁掉的元凶），刷新按钮给到 minWidth 22 + 右侧内边距 22。宽度预算（2026-11 加了缩略图大小滑杆之后）：搜索 100 + 排序 100 + 升降 44 + 分组 84 + 视图 68 + **缩略图大小 103** + 刷新 22 + 间距 48 = **569**，+ 左右 40 = **609 ≤ 内容区最小 610**；窗口最小 **1030**（236+1+610+1+180 = 1028）。列表视图没有那根滑杆，少 111。**底栏高度固定 38pt**，换提示 / 换选中态都不许长高。
- 三态样式（缩略图 + 列表 + 预览三处口径一致）：**悬停** = 图内推近 **1.12** + 轻微提亮(0.03) + **柔和大阴影（radius 14 / y 5 / 34%）** + 一条 **2pt 白 78% 头发丝边**（苹果相册那种）。**不要做成「白晕 + 黑边」的双层套框**（用户原话：太丑）；显著性靠「浮起来」的阴影和轻微推近，不靠描边堆料。**格子本身绝不能 scale**（会从鼠标下面长走 → leave/enter 抖动）；**选中** = 强调色 3pt 环 + 14% 铺色 + 右上角勾；**标记回收** = 橙色 2.5pt 环 + 18% 橙铺 + 图压到 55% + **左上角橙色垃圾桶（10pt，比别的角标大一号）+ 右上角橙色圆叉（22pt）**。**放大只作用于里面那张图**（外层格子尺寸和命中区不变），否则会触发 `经验文档/SwiftUI-版式与崩溃.md` 里那条 hover 抖动。
- **取消标记 = 再点一次（2026-11 三轮定案，2026-11 加压缩，不再有单独按钮）**：单击已标记的格子/行 → 撤销标记回到正常；**再点一下才是选中（蓝）**。顺序写在 `AppStore.toggle`：先看 `pendingDeletions`（命中 `unmark`）→ 再看 `compression.contains`（命中 `unmarkCompression`，2026-11 用户要求，**回收站和压缩站两套完全一致**）→ 都没有才动选中。另一条通路是预览里的 ⌫（回收）/ `-`（压缩）。**框选和批量拖拽一律不取消标记**（拖一下撤掉一整片太容易误伤）。已标记的项（回收**和**待压缩）不进选中集合（`toggle` / `extend` / `selectAll` / `togglePreviewSelection` 四处都拦），所以勾和标记角标永远不会同时出现。
- **框选多选（2026-11 新做）**：网格 / 列表 / 回收站都能按住拖出选框。手势挂在**内容容器**上、坐标用内容自己的 named space（滚动时格子坐标不变，不重算）；格子位置用 `CellFramePreference` 收集，**只在命中集合真的变了才写 selection**。口径是用户定的：**框住的直接并入已选**，不做「只选框中」；`MarqueeMode` 只剩 `.select` / `.deselect` 两档。`UI/Marquee.swift` 是这套的公共件。
- **动效（2026-11 三轮）**：全部常量收进 `UI/Motion.swift`（`page` / `fade` / `pop` / `sheet` / `reveal` / `thumb`）＋ 三个转场（`.badge` / `.cellRemove` / `.dialog`），各处不再随手写 duration。**换页**（侧栏 / 相簿 / 网格↔列表）走 `.pageReveal(store.pageKey)`：整块淡入 + 0.985 微缩，0.85s（只用于照片/相簿/回收站换页），**故意不做逐格错峰**（5000 张一起动就卡）；搜索和筛选不算换页，不重播。**缩略图到手**单张淡入。**选中 / 标记 / 取消标记**用 `Motion.pop`（spring 0.42）；勾、垃圾桶、叉都带 `.badge` 转场。**回收站删条目**用 `.cellRemove`。**弹窗**（`EmptyTrashSheet`）内容 spring 入场。**概览也走 `pageReveal`**（2026-11 改回，见下面「概览页动画与排版」那条），用的就是这一套 `Motion.page`，口径和照片页完全一致；但 `CountUpText` 数字滚动 / 卡片错峰 / 左右栏推入 / `contentRevealCount` 令牌**依然不做**，用户要的只是「整块淡入」这一个动作。
- **术语统一（2026-11）**：照片页/预览 = 「标记回收」，底栏 = 「已标记 N 项」；回收站页 = 「彻底删除」。**标记不二次确认**（回收站本身就是保险，两层够了），`presentDeleteConfirm`/`confirmDelete` 已删；**系统 sheet 只剩一处** = 回收站里的彻底删除（`EmptyTrashSheet`，原 `ConfirmSheet.swift` 已改名）。`AppStore.purge(_:)` 是唯一动设备真删的入口，清空整站和删选中几条都走它。
- **删除全程可见（2026-11 用户要求，别退回去）**：点完「彻底删除」界面**必须立刻有反应**，否则用户以为崩了、强退，内存里的回收站名单就丢了。三块东西：① `PurgeProgress`（`UI/PurgeStatusOverlay.swift` 的 `PurgeProgressCard`）—— 厚材质盖死整窗、进度条、`第 101–200 项 · 共 600 项`、正在删的文件名、`已删 x · 失败 y`、一句「别拔线别锁屏，45 秒没回执会自动停下」；② `PurgeReport`（`PurgeResultCard`）—— 标题写 `已删除 N 项，M 项没删掉`，失败项**逐条**列「文件名 · 大小 · 具体原因」（可滚动、超过 50 条写「还有 N 项」），按钮「关闭 / 重试失败的 N 项」；③ 底栏留一句短的（悬停看全文），弹窗关了也看得到。
- **这两块是 overlay 不是 sheet**：确认 sheet 刚 dismiss 就 present 下一个会被 SwiftUI 顶掉（现象＝点了删除什么都没发生），而且删除中必须盖死整窗。位置在 `RootView` 的 `.overlay`，**排在预览层之后**。遮罩期间 `handleKeyEvent` 吞键盘，但 **Esc / ⏎ 必须放行**（结果单那两个按钮靠 `keyboardShortcut` 接）。
- **设备上已经不存在的项不再算失败（2026-11 二次修）**：手机上删掉的照片（尤其进了「最近删除」的）PTP 不报 `didRemove`，界面留着它、还按库匹配出「已压缩」角标，一点删除就报「找不到条目」，人卡在回收站里出不去。现在 `PTPBridge.delete` 把这种情况标成 `gone`（文件表**非空**、偏偏没这一条才算；表空仍然报「等几秒再点一次」），`PurgeEngine` 把它连同成功项一起从回收站移除，`AppStore.purge` 再把它从 `assets` / `convertedAssets` / 缩略图里一起清掉，结果单写「另有 N 项设备上已经不存在，已从列表和回收站移除」。
- **删除失败必须逐条给原因**，来源只有三处：`ICDeleteError` 的逐条回调（`PTPBridge.message(forDelete:)` 按 ReadOnly / Permission / NotFound / Cancel / Unavailable / InvalidParam / Failed 分类）、`设备上已找不到这个文件`、超时。**`PTPBridge.delete` 45 秒没回执（`deleteTimeout`）就收尾**，这一批没回执的逐条标原因并返回 `timedOut`；`PurgeEngine` 见到 `timedOut` **立刻停**，剩下的标「没有执行」。以前没有这道闸，`requestDeleteFiles` 的 completion 不来就永远转圈。
- **删失败的东西不消失**：`PurgeEngine` 只 `trash.remove(succeeded)`，失败项原样留在回收站，结果单里能一键重试（`AppStore.retryFailedPurge()`）。
- **预览层（2026-11 重做）**：进/出场是**从悬停那一格长出来**（`HoverProbe` 在 onHover 时记下该格在 `PreviewAnchorSpace.root` 里的矩形 → 归一化成 UnitPoint 当缩放锚点，拿不到就居中），spring 0.34 + 阻尼 0.86，退场缩回去再拆（`isClosingPreview` 撑 180 ms，`closePreview()` 只是请求关闭）。⚠️ `RootView` 里 **不能再给 PreviewOverlay 加 `.transition(.opacity)`**，否则缩放会叠一层淡入。快捷键：⏎ 选中 / S 同 ⏎ / **⌫ 标记回收 ↔ 取消** / **`-` 标记压缩 ↔ 取消**（两者互斥，后按的说了算）/ 空格关 / ←→ 切换。顶栏那排键帽（空格 / ←→ / ⏎ / ⌫ / **`-`**）**本身就是按钮**，可直接点；状态胶囊除了「已标记回收」「已选中」还有**「待压缩」**。**键盘走窗口级 `KeyMonitor`（NSEvent local monitor），不再用 `.onKeyPress`** —— 那套要求焦点在根视图上，鼠标点过预览键帽或播放器抢走 first responder 之后 ⌫ 就收不到了（用户报的「预览里按退格没用」）。输入框有焦点时监听让路，打字不会被吞。**标记、取消标记、选中都留在原地、不自动翻页**（2026-11 三轮用户定的：状态胶囊当场变就是反馈，自动跳走反而不知道动的是哪张）；想换就 ← →。提示从右下角搬到顶栏右边；已选信息补了体积。
- **回收站页（2026-11）**：搜索 + 排序（标记时间/大小）+ 升降序 + 网格/列表 + 单击/⇧连选/框选 + 底栏批量「放回去 / 彻底删除」。
- **刷新按钮（2026-11 修）**：以前 `startScan` 里 `resetScan(skipLibrary: libraryDone)` 把库整段跳过，`forceLibraryRefresh` 全项目只写不读（5 处赋值 0 处读取）→ 点刷新什么都不变；顺带 `cacheBar` 用 `if !store.isScanning` 把左下角那块整个藏起来，看着像"清空不见了"。现在刷新**真重读库**（`skipLibrary: false`）、死标志已删、左下角那块**扫描中也不消失**只置灰 + 显示「正在读取…」。**刷新时不许停 `ICDeviceBrowser`**（2026-11 二次修，见下一条）：`killStrayHelpers` → `releaseDeviceFiles` → `loadLibrary` → `ptp.refreshCatalog()`（只解开关会话）。
- **「手机上删了还显示 / 新拍的不显示 / 回收站删不掉 / 点重新读取卡住」是一条链（2026-11 二次修，四条一起出现别再当四个 bug）**：界面列表只来自 PTP 那一份快照（`onCatalog`），手机端删照片、锁屏、被「照片」/访达抢会话之后不会有 `didRemove`；而刷新那条路原来是 `stopPTP` → **`startPTP`** → 等目录 → `loadLibrary`，顺序做反了 —— 有 ICCamera 会话时子进程的 AFC 打不开文件（`retryLibraryOnce` 的注释里就写着），读库注定 30 秒出不来 `SIZE` → 90 秒总限 → 失败，这期间 `isScanning` 一直 true、按钮全 disabled。**真正的元凶是 `browser.stop()`：停掉之后设备再也不回到 IC 的列表里**（换三个新实例 `start()` 一条 `didAdd` 都没有，手机还插着、AFC 读库正常，PTP 却永久空掉，只能重启 App）——所以 `stopPTP()` 只能用在终态（切模拟设备/未连接），刷新、重读库、压缩一律改成只 `ptp.pauseSession()` / `ptp.refreshCatalog()`。现在：① 刷新 = `killStrayHelpers` → `releaseDeviceFiles` → `loadLibrary` → `ptp.refreshCatalog()`（解开关会话，`catalogFinishSent` 要清，否则收尾不触发）；② 刷新**不再清 `assets`**（清了但枚举回不来就是一屏空白），枚举成功由 `onCatalog` 整份覆盖，会话掉了只 flash 一句；③ `scheduleScanDeadline` 改**心跳式**（只看目录安静了多久）；`resetScan` 先撤旧闸，否则旧闸会在读库中途醒来写假的「读不到照片目录」；④ `DeviceFiles.reset(timeout:)` 带 3 秒上限（原来 `queue.sync`，设备不回包就永不返回）；⑤ `retryLibraryOnce` 一进去就置 `libraryRetrying` + `libraryRetryInFlight` 防连点；⑥ 删除前等文件表 **15 秒**，「目录没读完」和「设备上真没有」分开说；`cameraOrReconnect` **平时不碰 browser**，只有 `camera` 已经为 nil（会话真掉了）时才换新实例重开，见「压缩成功后原图全删不掉」那条。真机实测见 `经验文档/设备通路与照片库.md` 8.10。
- 时间小标题（2026-11 三轮）：**一行纯文字**，不装卡片 —— 日期 18pt bold rounded，同一行后面跟灰色「123 项」。列表模式会吸顶，那时才在底下垫一层 `.bar`（`DateHeader(pinned:)`），网格不吸顶就不画底。
- 框选只有两种模式（2026-11 三轮）：**按下那一刻按"按住的那一格"定死**，中途不换 —— 那块已全被选中 → 这次拖动是**取消选中**；否则并入已选。**没有"取消标记"这一档**了（见上面「取消标记只有两条人工通路」）。
- 预览不再收栏（2026-11 二轮）：`RootView` 原来 `if showSidebar && store.previewID == nil` —— 一开预览窗口内容区变宽，LazyVGrid 重排列数，关掉再回来网格整体跳一下（用户报的"视图位置会变 / 会缩一下 / 会划走"）。现在**预览时左右两栏照旧**（预览层本来就整窗盖死，收不收看不出来），网格布局完全不动。
- 预览顶栏那 4 个键帽（2026-11 二轮）：**既是快捷键提示也是按钮**，可直接点：空格关闭 / ←→ 下一张 / ⏎ 选中（已标记时置灰）/ ⌫ 标记回收（已标记时变「取消标记」）。infoBar 里重复的两个按钮已删，只留「已选 N 项 · 体积」。
- **已标记回收的项不进选中集合**：`toggle` / `selectAll` / `togglePreviewSelection` 三处都拦了，不然同一条既"待删"又"已选"。
- 概览排版（2026-11 三轮）：**没有顶栏、没有底部脚注**；卡片标题 13 semibold + 10pt 色块；「照片类型 / 相簿大小」每行统一 **名称 → 条 → 项数 → 体积**（条紧贴名称右侧、尽量长，项数紧贴体积左边），条高 8pt。
- 概览质感（2026-11 四轮）：6 张卡片和两张排行块统一走 `cardSurface()`（`UI/Components.swift`）= **14pt 圆角 + 自上而下 12% 白色高光 + 1px `primary.opacity(0.07)` 细边 + 5% 黑投影(radius 7, y2)**；数字 23pt rounded semibold。别再各写一套背景。
- 概览「照片类型」（2026-11 二轮）：不再是"照片/截屏/视频"三分，改成**和侧栏同一套分类**（相机/照片/视频/收藏/截图/实况/RAW/已隐藏/最近删除），按体积从高到低（`AppStore.typeRanking` ← `filterMetrics`）。
- **概览页动画与排版（2026-11）**：概览改用 `pageReveal(store.pageKey, blocked: revealBlocked)`，和照片页**同一套**（`Motion.page`：easeOut 0.85s，整块淡入 + 从 0.985 微缩），不逐卡错峰、不数字跳变。`blocked` 是修「启动进概览看不到动画」的关键 —— `onAppear` 比窗口上屏早得多（实测窗口约 0.46s 才上屏，而 onAppear 在那之前就跑完了 0.85s 动画），靠改 key 重播也不成，动画会在门禁遮罩底下播完；现在启动期间概览保持**全透明**，等 `needsLibraryGate` 撤掉且 `hasStats` 就绪才开播（6 秒兜底）。排版：卡片最小宽 168 / 最小高 88，卡片间距 14，块间距 20；「照片类型 / 相簿大小」宽度 ≥ 620 才并排，否则**上下排**（并排时横条会被名称/项数/体积三列挤成几个像素）；排行行距 3；**底栏必须 `.frame(maxWidth: .infinity)`**，外层是 `VStack(alignment: .leading)`，不给就只到最后一个字、右边露窗口背景。
- **实况照片预览播放（2026-11）**：库里 `subtype == 2 && playbackStyle == 3` 判实况（本机 1937 条），视频分量按「**同目录、同 basename、`.MOV`**」取（`--probe-livefiles` 实测 410 组配对、`--probe-livefetch` 20/20 命中）。预览里静态图永远打底，视频到了盖上去**只放一次**，播完停在静态图，点左上角「实况」按钮才重播（**不循环**，循环播放静音也很烦）。视频还没取到时角标写「实况 · 正在取回」。
- **压缩站（2026-11 三轮，用户定的两步流程，别退回一步）**：照片页底栏的「**标记压缩**」和「标记回收」**同一套出现逻辑与样式**（只有选中了才出现、同在右侧那组、同一种小按钮），点它只打开参数面板，里面点「标记压缩」也只是标记（`AppStore.markForCompression(profile:)` → `CompressionQueue`，只在内存；格子**浅黄色完整样式**「待压缩」（和标记回收同一套三件套：2.5pt 黄环 + 22% 黄铺 + 左上角黄胶囊（深色字，黄底压白字读不出来）带压缩图标；图不压暗），**黄胶囊里直接写这张会怎么压** —— `60%·HEIC·Q80`（`ConversionProfile.badgeText`；2026-11 用户要求「每个缩略图都要显示我们怎么压、什么格式、什么百分比质量」，别再只写「待压缩」三个字）；列表行同一份文案（`待压缩 60%·HEIC·Q80`），预览的状态胶囊用全称 `profile.label`，格子的 tooltip 也带上「标记压缩：…（再点一次取消）」。列表模式是黄色胶囊标签（2026-11 四次改：蓝色胶囊→撞选中色；深色小胶囊→不够「像其他样式」；灰色三件套→不够显眼；最后定**浅黄**：蓝＝选中、橙＝待删、绿＝已压缩，黄正好空着），侧栏「设备 › 压缩站」显示条数），**不动设备**；到**压缩站**里二次确认（`runCompressionStation(ids:)`，`ids == nil` = 全站）才真压。理由：压缩要改 `Photos.sqlite`，**每次写库 302 MB 双向**，压一张 1 MB 的图也是这个价 —— 所以逼着用户攒一批。**压缩站页面和回收站同构**（2026-11 三次改，用户要「一模一样」）：搜索 / 排序（放入时间 / 大小）/ 升降序 / 网格⇄列表 / 单击·⇧连选·框选 / 底栏批量 —— 空选时是「清空压缩站 + 开始压缩 N 张」，有选中时是「已选 N 张 + 移除 + 压缩选中 N 张 + 取消选择」。按**参数分组**跑（不同比例/格式各跑一组，**每组一次写库**，底栏写「N 组参数 · 每组都要写一次库」），成功的移出名单、失败/跳过的留着能再点。**「写回手机相册」开关已删**（2026-11 三次改）：压缩完一定 `writeDB: true` + 重启 `assetsd`，不进相册等于没压。视频不进压缩站（暂不支持）。**同一项只能带一个标记（回收 / 压缩）**：后标的一方生效、另一方自动撤销 —— 标记回收会把该项从压缩站移出并提示「其中 N 项已从压缩站移出」；标记压缩会把该项从回收站移出并提示「其中 N 张已从回收站移出」；预览里按 ⌫ 标记回收同样撤掉压缩标记；压缩成功把原图送进回收站时也顺手把它从压缩站名单里去掉。
- **压缩参数要记住（2026-11 用户要求）**：比例 / 格式 / 质量 / 去实况 存 `<数据目录>/compression-prefs.json`（`Core/CompressionPrefs.swift`），**跨启动**：`ConversionSheet` 的** `init()` 里 `CompressionPrefs.load()` 逐条 `State(initialValue:)`**（⚠️ **不能用 `static let saved` 缓存** —— static 在进程内只求值一次，同一次运行里改成 40% 再打开面板还是 60%，用户报过「记不住」，只有重启才看起来正常；坑的完整说明见 `经验文档/SwiftUI-版式与崩溃.md` 第十三节）；拖滑块 / 换格式**当场落盘**（`onChange` → `save()`，不等点「标记压缩」——用户原话「每次新设置的都记住保留」，中途关掉面板也算设置过）；预览里按 `-` 用的 `AppStore.lastCompressionProfile` 也从这里初始化。**这份文件是全项目唯一主动保留的落盘**（理由与清场例外见「不留痕」那条），别把它加进 `TraceRegistry.fileNames`。
- **压缩回写（2026-11 二次修，2026-11 定案）**：`Core/Conversion/` 走的是**旁路** —— 副本写进 `/DCIM`，再**改 `Photos.sqlite` + 重启 `assetsd`**，手机相册就认得（用户实测能看到）。代价是**每批一次 302 MB 双向**（`fetchFreshDB` 整份下 → `ConversionDB.apply` 插行 → 整份写回 → `restartLibrary`）：iOS 没有登记资产的公开接口、AFC 只能整文件覆盖，所以**压一张 1 MB 的图也是 300 MB 上下**，能省的只有「**一批只写一次**」——所以界面上多了「压缩站」这一步：先标记、攒够再一次性写（**没有「写回手机相册」开关**，写库是压缩的必经步骤）。⚠️ **压缩完 App 里必须自己补列表**：写进 DCIM 的文件 PTP 不会立刻报出来（目录是快照），所以 `injectConvertedCopies(result)` 用转换记录补进 `assets`，`onCatalog` 里 `mergingConverted(list)` 按 id 合并。⚠️ **结果卡的「省了多少」只认 `ConversionRecord.originalSize`**：旧代码在 `clearSelection()` 之后回列表捞原图大小，捞到 0 → 把「省 2 MB」显示成「体积增加 332 KB」。正确口径是三段：副本合计 / 原图合计 / 彻底删除后的净省。详见 `经验文档/设备通路与照片库.md` 10.5。
- **往设备回写照片：三条路全封（2026-11 实测，别再试）**：Airlock 服务 `-402653150`（`0xE8000022` 服务受限）、`com.apple.afc2` 同码、`ICCameraDevice.requestUploadFile` 回 `Upload files failed`（头文件从 macOS 14 起标了 sandbox 限制）。`/Photos` 存在但空、`/Photos/Sync` 打不开。这三条直路别再试；**但旁路是通的**（见上面「压缩回写」那条：写 DCIM + 改 `Photos.sqlite` + 重启 `assetsd`），压缩功能现在就走它。详见 `经验文档/设备通路与照片库.md` 第十节 / 10.5。
- **修改站（2026-11 新做，真机验证通过）**：收藏 / 移动相簿 / 新建相簿三件事都走**旁路写库**（整份改 `Photos.sqlite` → 写回 → 重启 `assetsd`），已实测手机上全部生效。因为每批固定 40–60 秒（297 MB 上下），交互和回收站/压缩站一致：**点 ♥ / 移动只是暂存**（`PhotoEditQueue`，只在内存），到「修改站」点「写回手机」才动设备，**整批只写一次库**。入口：格子/列表右键、预览里的 `♥` 键帽、底栏选中后的「收藏 / 移到相簿」；侧栏「修改站」显示暂存条数。合并规则：同一张反复点只留最终态（收藏点回原样就消失，移动合并成「源 → 目」）。压缩在跑时点写回会排队，压缩结束自动提交，并把暂存的收藏/相簿**改指到压缩生成的新副本**；压缩自动标进回收站的原图标成「已压缩待删除」（brown），和你手标的橙色分开计数。⚠️ 改库细节（实体名不在 `Z_PRIMARYKEY` 里、新建相簿必须复制「用户自建」那种行、`Z_FOK_3ASSETS` 是同一本相簿内 1024 递增）全在 `经验文档/设备通路与照片库.md` 第十一节，改这块之前必读。
- 未做：标记/彻底删除流程的**真机**回归（只做过模拟设备 + 界面走查；真机的超时分支和逐条失败原因还没在现场见过）。界面回归用 `CMI_FIXTURE=1 CMI_PURGE_DEMO=<条数>`（配 `CMI_FIXTURE_DELAY` / `CMI_FIXTURE_FAIL` 造慢速与失败）；「点重新读取」那条路用 `CMI_AUTO_REFRESH=1` 自动触发一次（真机，只跑一轮），见 `经验文档/构建与调试.md`。
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
| `scripts/make-dmg.sh` | 发给别人用：arm64 + x86_64 各编一次 → 通用二进制 → `.app` → 同时出「文件夹 / zip / DMG」三份同内容包（每份都是 App + `首次打开.command` + `使用说明.txt` + `/Applications` 快捷方式） |
| `scripts/dmg/` | DMG 里那两个给人看的文件（`首次打开.command` / `使用说明.txt`），改文案只改这里 |
| `Package.swift` / `Makefile` | SwiftPM 与常用命令（`make app` / `make dmg`） |
| `build/` | 产物（`.app`），不提交 |
| `dist/` | 打出来的三种同内容产物：`cleanmyiphone-<ver>/`（文件夹，直接发）、`.zip`（压缩发）、`-universal.dmg`（最稳），不提交 |
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
- 库门禁（2026-11 三轮，已升级成「任何页面都盖」）：`libraryIndex == nil` 时**整窗盖死**，遮罩挂在根视图（`RootView` 的 `.overlay` + `store.needsLibraryGate`）。**只有两个例外不盖**：暂停态（`dataPaused`，要能点「重新读取」）和未连接（`needsConnection`）。**锁屏也盖**，卡片写「设备已锁屏 / 解锁后自动继续读取」，解锁由 `unlockWatch` 自动重读；点「重新读取」时 `retryLibraryNow()` 先清 `isDeviceLocked`，`libraryRetrying` 期间门禁**继续盖着显示在读**（`libraryReadingNow`），失败原因降级成一行小字 —— 用户原话「不要先进去再读取」。`PhotosView` 里那层只留暂停态的「本机数据已清空」卡片，别做成双层。空格预览在库没好时仍然直接 `return`。
- 预览通道（2026-11 修）：`downloadByDevicePath` 走**独立的 AFC 会话 + 独立串行队列**（`previewSession` / `previewQueue`），不再和整屏缩略图挤在 `queue` 上。之前首次进照片页那串缩略图（每个都要在 `downloadLocked` 里 `buildIndex()` 枚举 /DCIM）会把队列顶满，预览排在后面 → 卡片上只有转圈、一个字节都没有，关掉再点别的又正常（因为索引已经建好）。建不起第二条会话时自动回退共用通道，并置 `previewChannelBroken` 不再反复试，`reset()` 清掉该标志。`download(priority: true)` 也走这条通道。
- 取回路径顺序（2026-11 修，实测踩过）：**AFC 绝对路径（库里查得到）→ AFC 名字匹配（/DCIM 索引）→ IC 单流兜底**。原来 IC 排在名字匹配前面，而 PTP 报的名字经常是随机的（实测 `HPQE7329.MP4`，磁盘上是 `IMG_7329.MP4`），`meta(asset)` 查不到就直接掉进 IC → 开头几秒一个字节都没有，卡片显示「正在等待设备通道」。现在 `meta()` 多一层「数字后缀 + 同扩展名」在库里兜（要求唯一命中），查不到也先走 AFC 名字匹配。
- 门禁不会总出现：库在启动阶段就读完时（正常情况，也会打印「库索引就绪（门禁撤）」），进照片页时 `needsLibraryGate` 已经为 false。要验证遮罩得在库读取期间进照片页，或删掉快照重来。
- **性能红线**（2026-11 踩过一次，界面卡死几分钟）：任何「按名字 / 后缀找」的查询都必须走**预建索引**（`PhotoLibraryIndex.fileNameByDigits`），不能在查询里现扫 `metaByFile`。**同理，网格每个格子每帧都在问「这张已标记吗 / 待压缩吗 / 什么参数）」——`TrashStore` 和 `CompressionQueue` 都维护 `byID` 字典（`contains(_:)` / `entry(for:)`），统一走 `store.isPending(_:)` / `store.isQueuedForCompression(_:)` / `store.compressionProfile(for:)`，别在 body 里现拼 `Set(entries.map(\.id))` 或 `first(where:)`。`meta()` 对每张资产都会被调（`tagSet` / `computeVisible` / 侧栏统计），5000 张 × 5000 条字符串过滤 ≈ 2700 万次，全在主线程 → 界面卡死、进度不刷新，表现成「读索引读了 3 分钟」。`AppStore.meta()` 另加一层 `metaCacheStore`，`libraryIndex` 更新时要 `removeAll()`。
- **子进程收尾（2026-11 定案，比"防孤儿"更重要）**：`kill -9` 掉卡在 AFC 调用里的 helper 会把**手机侧 afcd 的通道搞坏**——之后 `--probe-afc` 一律 `连接被关闭`、`--fetch-library` 连 `SIZE` 都打不出来，而 PTP / lockdownd / `isLocked` 全部正常。恢复只能拔插数据线或重启 iPhone。所以退出必须走 `Probe.HelperGuard`：`AFCConnectionInvalidate`（放出阻塞读）→ `AFCConnectionClose` → `AMDeviceStopSession` → `_exit`。触发点三条：`SIGTERM/SIGINT`、**父进程死亡**（父进程拿一根永不打字的管道当子进程 stdin，父进程一死子进程 `read(0,…)` 得 EOF）、正常读完的 `defer`。`getppid()==1` 只在 `report()` 里，卡在第一个 AFC 调用上永远轮不到。父进程侧 `stopHelper`：`terminate()` → 等 2.5 秒 → 才 `SIGKILL`；`killStrayHelpers` 也是先 SIGTERM、**等满 2.5 秒**（用 `pkill -0` 轮询确认真退了）才 `-9`。**看门狗 30 秒**（原来 15 秒太急：设备刚枚举完，AFC 首个回包常要 10 秒以上，一急就 SIGTERM 一个正卡在 AFC 调用里的子进程），总时限 90 秒，296 MB 实测 8–10 秒。
- **完整性与"读了一半当成功"（2026-11 修，这是"数据都不对"的元凶）**：helper 的 `CHECK > 0` 只证明「拿到的这份主库 + WAL 自洽」，证明不了「和刚才量到的 `SIZE` 一致」。AFC 半死时每个文件都会「成功地」只读回一部分，只要主库上次 checkpoint 之前的内容还在，`quick_check` 就过、`ZASSET` 也有行 → 旧的、缺了 WAL 里最新照片的库被当成成功快照，视频数和体积全对不上。现在 `OutputPump` 记下 `SIZE`/`PROGRESS` 的终值，`runFetchHelper` 出结果前对账：**少超过 0.5%（或 512 KB）就抛 `ServiceError.incomplete`**，`fetchOnMain` 因此在 copy 之前就 throw，上一份可用快照原地保留。`ServiceError.incomplete` 以前是死代码，现在真的会抛。
- **重抓前必须让出通道**：`retryLibraryOnce` 除了 `ptp.pauseSession()`（**只关会话，不能 `stopPTP()`**，见上面那条）还要 `releaseDeviceFiles()`（异步调 `DeviceFiles.shared.reset(timeout:)`，带 3 秒上限、不阻塞主线程）——否则缩略图的 `photoSession` 和预览的 `previewSession` 还攥着两条 AFC，加上 helper 就是三条压在同一根管子上。读完再 `ptp.refreshCatalog()` 让目录重推。
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
  **实测**（2026-11-01，真机）：启动/退出后 `ls -A ~/Library/Application Support/cleanmyiphone` 只剩 `instance.lock`（+ 现在的 `compression-prefs.json`，见下面那条）、`$TMPDIR` 无残留、`.ips` 29→0、`/tmp` 调试日志无。**2026-11-01 又补了两处（发给别人用之前必须干净）**：① `~/Library/Preferences/local.cleanmyiphone.plist`（窗口位置 + 屏幕尺寸）和由它派生的 `savedState` / `Caches` 现在也删 —— 但 cfprefsd 是**退出那一刻**才刷盘的，进程内删不掉，所以 `purgeOnTerminate()` 末尾调 `TraceRegistry.schedulePostExitSweep()`，起一个脱离自己的 `/bin/sh`：`sleep 1.2` → 删偏好 + 空掉的整个数据目录（**目录里只剩 `instance.lock` 才删**，避免刚退出又被打开时误删新实例的东西）。② 裸二进制跑出来的 `CleanMyiPhone.plist` 也算同一份痕迹，`preferenceDomains` 把 bundle id、固定 `local.cleanmyiphone`、可执行文件名三个域都列进去。实测退出 3 秒后：数据目录整个不存在、`Preferences` 里两个 plist 都没了、`$TMPDIR` 无残留。**③ 中转文件 `Photos.sqlite.new` / `.new-wal` / `.new-shm` 原来不在清单里**（清单只写了转正后的 `Photos.sqlite`）：退出那一刻正在下库时，几十上百 MB 的中转文件会留在盘上、目录也就删不掉（2026-11-01 打包后复测才发现）。现在这三个名字进了 `fileNames`，退出后那个 sweep 也会先 `rm -f` 再判目录是否可删。**实测**：起 App → 读到只差一半（目录里只有 `Photos.sqlite.new`）→ `kill -TERM` → 4 秒后数据目录整个不存在。SIGSEGV 实测：崩溃前目录里有四件套，崩后目录空。
  **唯一例外 —— `compression-prefs.json`（2026-11 用户要求记住压缩参数）**：存在数据目录里，**故意不进 `fileNames`、也不 `registerTrace`**，所以四个清场时机都不删它（`schedulePostExitSweep` 那条「只剩 instance.lock 才整棵删」因此不会命中，目录会留着）。理由：内容只有比例/格式/质量/去实况四个值，**没有任何照片信息、也不记录压过哪些照片**；进了清单就等于「记住参数」永远做不到。改零痕迹时别把它顺手加进清单，否则压缩参数每次回到 60%/HEIC/Q80。
  **手动清空（`purgeLocalData`）现在连内存一起清**：库索引、相册列表、assets、缩略图、回收站全丢，界面真的空着；点「重新读取」才重新读设备。侧栏不再有「自动清空」勾选框（开关本身就是痕迹，且关掉它等于允许留 296 MB 复印件），改成一行文案「退出即清空 · 本机不留缓存」。
- **分发（2026-11-01 新做：发给别人用的安装包）**：`make dmg` 一次出三份**内容完全一致**的产物 —— `dist/cleanmyiphone-0.1.0/`（文件夹：App + `首次打开.command` + `使用说明.txt` + `/Applications` 快捷方式，直接 AirDrop）、`dist/cleanmyiphone-0.1.0.zip`（`ditto -c -k --keepParent` 打，保留可执行位，微信/邮件用）、`dist/cleanmyiphone-0.1.0-universal.dmg`（3.0 MB，最稳）。arm64 / x86_64 各编一次再 `lipo` 合成通用二进制（两片实测 `minos 14.0`，Intel 和 Apple 芯片的 Mac 都能跑）；没有 Developer ID，只能 ad-hoc 签名，`spctl -a` 必判 `rejected` —— 所以 DMG 里带 `首次打开.command`（`xattr -dr com.apple.quarantine` 再 `open`）和 `使用说明.txt`（源文件在 `scripts/dmg/`，改文案只改那里）。三件事实测过：解除隔离后能正常起、挂载态 `codesign --verify --deep --strict` 仍 `valid on disk`、退出 3 秒后数据目录与偏好 plist 全部消失。朋友端要求只有 macOS 14+ 和一根数据线，**不需要装任何依赖**。细节见 `经验文档/构建与调试.md` 第七节。
- **压缩成功后原图全删不掉 = 同一个断线问题的第二个诱因（2026-11 现场）**：压缩最后一步 `PhotoDaemon.restartLibrary` 会 terminate 设备上的 `assetsd` + 「照片」App，IC 立刻报 `didRemove` → `camera = nil`，而浏览器是一次性的、不会再 `didAdd` → 之后删除整批「设备未连接」。**这不是用户手机的问题**，报「解锁 iPhone」是误导（解锁没用，**拔插一次数据线**才有用；而且**不能退出 App**，回收站名单只在内存里）。现在：`PTPBridge.cameraOrReconnect` 在 `camera` 为 nil 时会 `browser.stop()` → `replaceBrowser()` → `browser.start()` **换新实例多轮重开**（8 秒一轮，最多 20 秒；原来只 `start()` 干等，浏览器活着时那是空操作）；`runCompressionStation` 在 `daemonRestarted` 时**立刻** `await ptp.cameraOrReconnect(timeout: 25)` 并把结果 flash 出来。详见 `经验文档/设备通路与照片库.md` 8.11。
- **PTP 会话自己断掉 = 删除整批失败 + 界面永久转圈（2026-11-01 现场，0.1.1 修）**：iPhone 锁屏 / 空闲太久 / 被访达或「照片」抢设备时，设备侧会关掉 PTP 会话，`camera` 变 nil，而 App 里的照片、勾选、回收站都还在。两个表现：① 「彻底删除」→ `guard let camera` 整批退回，界面写「成功 0 项，失败 N 项，设备未连接」（**一项都没碰设备**，手机上文件完好）；② 正在扫描时 `catalogDone` 永远不来 → `isScanning` 永远 true → 顶栏刷新按钮**永久禁用**、界面卡在「正在读取照片目录」，⌘R 和拔插数据线都无效，只能重启 App（重启会丢内存里的回收站标记）。修了两处：`scheduleScanDeadline()`（30 秒，挂在 `startScan` / `connectRealDevice` / `beginSession` 三处，`finishScan` 里 cancel）强制收尾 + 解锁刷新按钮；`PTPBridge.delete` 开头先 `cameraOrReconnect(20s)`（camera 为 nil 时**换新浏览器实例多轮重开**，见上面「压缩成功后原图全删不掉」那条；2026-11 之前那版只对已活着的浏览器调 `start()`，等于空等）再等文件表填上（**15 秒**，2026-11 由 3 秒改：3 秒对 4500 个文件的目录重填远远不够，会把「目录还没读完」误报成「设备上已找不到这个文件」），等于把「拔插数据线」搬进 App。**第二条没在真机异常态复核过**（会抢正在用的设备），最坏情况与修复前相同。细节见 `经验文档/设备通路与照片库.md` 8.8。
- 区域（2026-11 修）：`RegionInfo` 在不同读数上会**时有时无、且可能是字符串 `CH/A` 而不是字典**，两种形态都要认；`MQ0W3` 这种无尾码的型号只能靠 RegionInfo。
- 锁屏→解锁（2026-11）：锁屏时开 `unlockWatch`，每 2 秒问一次，解锁即自动重读。**`startScan()` 自己不依赖任何回调**：它直接 `await loadLibrary()` 再 `ptp.refreshCatalog()`，所以「会话没重开 → `onDevice` 不再来 → 库永远不重读」那条老路已经不会发生（2026-11 用户报的「停在正在读取相册索引一动不动」）。
- **一个相簿里的「张数」必须三处一致**（2026-11 修）：二级栏、网格项数、底栏是三个来源，以前会差几十条。现在：① 相簿视图**按成员名去重**（成员集合本身就是 `Set<String>`，见 `computeVisible` 的 `albumCovered`），一张照片只算一项；② 体积统一走 `totalBytes(of:)`（`meta.resourceBytes`，含编辑版与 Live Photo 视频分量），拿不到才退 PTP 大小。实测「微信」：库里成员 615 条 → 归一化去重 613；PTP 枚举 666（原件/编辑版/同名各来一条）→ 去重后 613；体积 877.9 MB ↔ 底栏 878 MB。
- **读取中只有一张遮罩**（2026-11 修）：以前「根视图」和「照片页」各有一套（一套是转圈 + 一行字，一套是标题 + 字节 + 进度条），同一个动作两处长得不同。现在统一 `LibraryIndexGate`，三行固定：`正在读取相册索引` / `正在读取 <文件名>` / `已读 x / y`，**总量还没到就显示「已读 x MB」+ 进度条不确定态**（原来 `libraryBytesTotal > 0` 之前只有一个空转的圈）。
- **顶栏不许溢出**（2026-11 三轮）：靠**算准宽度**保证，不靠横向滚 —— 那层 `.horizontal` 的 `ScrollView` 兜底**已经删了**，它就是裁掉右侧刷新按钮的元凶。照片页（网格视图，最宽那一档）：搜索 100 / 排序 100 / 升降序 44（文字）/ 分组 84 / 视图 68 / 缩略图大小 103 / 刷新 22 + 间距 48 = **569**，+ `PageToolbar` 左右内边距 40 = **609 ≤ 内容区最小 610**。列表视图不显示缩略图大小那根，少 111。回收站 / 压缩站页：搜索 116 / 排序 84 / 升降 44 / 视图 68 / 缩略图大小 103 + 间距 32 = **447**（各自都在 500 以内）。**概览页没有顶栏**（用户定的：刷新在左下角，页面上不再放按钮）。其它页面的顶栏一律不放标题。改任何一个控件的宽度，都要重算这两个总数。
- 三栏宽度（2026-11）：左栏 236、相簿二级栏 190、右栏 180 全部 **min = ideal = max**（定宽，不许被挤扁或裁字），中间内容区**最小 610**（顶栏 569 + `PageToolbar` 左右 40 = 609），窗口最小 **1030** —— 236+1+610+1+180 = 1028 < 1030，所以任何窗口尺寸下三栏和顶栏都完整、图片不被裁（列数自适应，单格宽度由用户调，84–200pt；默认 118）。改宽度时这几个数要一起算。
- **缩略图大小可调（2026-11 用户要求：「不要定死大小，需要可以调节」）**：`AppStore.thumbCell`（**84–200pt，默认 118**，2pt 一档吸附）是**唯一**的格子宽度来源，照片页 / 回收站 / 压缩站三个网格都读它（`GridItem(.adaptive(minimum: store.thumbCell))`；照片页按 `minCell + spacing` 算列数）。UI 三条通路：顶栏那根 103pt 的小滑杆（`ThumbSizeSlider`，**只在网格视图里出现**）+ 菜单「放大/缩小/还原缩略图大小」⌘+ / ⌘- / ⌘0。角标 / 圆角 / 内边距 / 描边全部乘 `store.thumbScale`（`thumbCell / 118`，夹在 0.78–1.7），否则 200pt 的大格子里角标会小得像米粒。⚠️ **这个值只在内存里、不落盘**（退出即清空，见「不留痕」）；⚠️ `handleKeyEvent` 现在**带 ⌘ 的组合键一律返回 false 交给菜单**（只自己接 ⌘A），不然本地监听会先把 ⌘- 抢走当成「标记压缩」。
- **预览顶栏：键帽和文件名不许重叠（2026-11 用户报的）**：以前是 `ZStack + 名字固定 padding(.horizontal, 340) + 右对齐键帽`，而键帽那一排本身 240–520pt，默认 1180 窗口下内容区只有 762pt → 必然压上。现在 `topBar(available:)` **先量再排**：键帽那一排用 `GeometryReader` + `PreviewHintWidthKey` 量出**自然宽度**（`.fixedSize` + `.layoutPriority(1)` 保证不被压缩，量出来才稳定），两侧各留这么宽还够给名字（≥150pt）就**单行居中**，不够就**键帽下移一行、名字独占一行**。**键帽上的文字一个字都不许删**（2026-11 用户定的），窄窗口只按 `HintDensity` 三档整体缩小（字号 12 / 10.5 / 9.5，门槛 1100 / 860，跟「单行居中需要 本排宽度×2+150」对齐）；真挤不下才把这排挪到第二行。infoBar 在 available < 660 时收起「类型/格式/相簿」三列，别把右边「已选 N 项」挤出窗口。
- **底栏两个标记计数（2026-11 六次改，百分比已删）**：左边是「N 项 · 总体积」，后面跟**两个独立计数**——`🗑 4 项 · 20.4 MB → 0`（标记回收）和 `⤵ 6 张 · 200 MB → 20 MB`（待压缩），字号 `.caption2`（比左边小一号）。**报的是这批标记项自己的「现在 → 之后」，不是占全库/当前列表的百分比** —— 中间那版拿「标记体积 ÷ `visibleBytes`」出百分比，而标记项本身还在列表里、分母又是整屏照片（本机 8.93 GB），200 MB 的标记只显示 2.1%；用户要的是「这批删完/压完能降多少」（2026-11 用户报的）。回收站删完即归 0，待压缩的 after 是**按每项自己标记时的参数估的**（`AppStore.compressionSizeChange` → `ConversionProfile.estimatedBytes(for:)`；压缩参数面板共用同一份系数，别再各写一套）。点它们分别进回收站 / 压缩站。**有选中时这两个计数自动让位**（底栏总宽只有 500，选中那组按钮已经占满）；没有任何标记时才显示右下角的操作提示胶囊。
- 侧栏底部（2026-11 改，二轮又改）：**读取中也一直显示**「退出即清空 · 本机不留缓存」+ 两个原生按钮（清空本机数据 / 重新读取）。以前是 `if !store.isScanning` 整个藏起来，点顶栏刷新时这块会闪掉一下，看着像「按钮没了」；现在只置灰，上面加一行「正在读取…」。按钮下方一行小字报结果或残留项。**没有「自动清空」勾选框了**（见上）。
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
- 包含什么：usbmuxd 已不可用的结论、MobileDevice 私有框架签名与五个坑、lockdownd 键名表（含真实可用空间键）、照片库表结构与相簿关联表探测、跨通路匹配策略、明确拿不到的四类数据（含电池健康度/温度为什么不行）、删除通道结论；**第八节：相册库 WAL 四件套快照**（整搬 main/wal/shm、不能用 seek 判大小、0 字节读要重试、PTP 会占设备、下载放子进程）；**8.1 读库卡几分钟的三个原因**、**8.2 收尾三步 + 单实例**、**8.3「数据不对 / 缩略图只出一部分 / 通道被关掉」三个独立毛病**（含 `thumb-log.txt` 行义表、完整性对账口径、AFC 好坏的两条探针）、**8.4 设备端缩略图缓存 `/PhotoData/Thumbnails/V2`**、**8.5 四层退出清场**、**8.6 视频缩略图/匹配四层**、**8.7 SQLite 列类型不固定的坑**、**8.8 PTP 会话断掉后删除整批失败 + 界面永久转圈（两道兜底与三处证据）**、**8.9 删除中的可见性与逐条失败原因（进度回调、45 秒无回执就停、`CMI_PURGE_DEMO` 回归）**、**8.10 `ICDeviceBrowser` 是一次性的（`stop()` 之后设备回不来，刷新必须只 `pauseSession` / `refreshCatalog`）、心跳式扫描闸门、`DeviceFiles.reset(timeout:)`、删除前等文件表 15 秒、`CMI_AUTO_REFRESH` 回归**、**8.11 压缩重启相册服务把 PTP 打死（`cameraOrReconnect` 换新浏览器多轮重开、压缩后立刻重连、失败文案改成「拔插数据线」、现场不能退出 App）**；**第九节**：iOS 26.7 实测（house_arrest 全关、GasGauge 只有 4 个键、AFC 根目录清单、App 清单、会话泄漏、设备端缩略图怎么做、按库路径取原文件）。
- 不用读：只改界面版式时。

**SwiftUI-版式与崩溃.md**
- 什么时候读：改界面、加图表、改侧栏、遇闪退或布局乱跳、写悬停/键盘交互、写加载态、加动画。
- 包含什么：四个直接崩溃的坑（`@State`+`@Observable`、焦点环、`VideoPlayer` 反解崩溃、列数回写）、加载中布局乱跳的根治、读取态只报字节不报百分比、**悬停与键盘焦点**（别用 scaleEffect、离开不清 hoveredID、点完格子要把焦点抢回来、预览层要不透明）、**别在 body 里做 IO / 别在 view update 期间改被观察的集合**、环形绘制与悬停手感、对齐与自适应习惯、图与卡片联动；**十二节：动效**（常量集中在 `Motion.swift`、换页淡入不能同帧改两次、不做逐格错峰、缩略图淡入要 transition+animation、角标 scale 转场、门禁重试期间必须继续盖着、**12.6 确认弹窗之后的长过程用 overlay 不用第二个 sheet，且 Esc/⏎ 必须放行**）；**十三节：`@State` 初值别从 `static let` 取**（进程级缓存导致「设置记不住」：退出重启正常、同一次运行内不正常，就是 `static let` / `lazy var` / 缓存字典）；**十四节：中间标题 + 右侧一排按钮**（固定 padding 的 ZStack 必重叠，正确做法是先量按钮排的自然宽度再决定居中还是换行、以及为什么测量前要给 `.fixedSize` + `.layoutPriority`）。
- 不用读：只调数据层时。

**构建与调试.md**
- 什么时候读：编译失败、要打包、要跑真机探针、要清空本地数据、要验零痕迹。
- 包含什么：外置卷 + 沙箱下必须带的构建参数、`make-app.sh`、**「`swift build` 通过 ≠ 用户能看到改动」（必须重新打包 + 用 `LC_ALL=C grep -a` 核验文案进没进二进制，`strings` 对中文无效）**、**用户启动的是 `build/` 里的包、别去替换 `/Applications` 那份**、探针开关与环境变量、`--fetch-library` 子进程、崩溃报告与截图调试习惯；**清空本地数据**（App 内入口 + 命令行 + 沙箱里 rm 会被拒的两种绕法）；**零痕迹验收**（数据目录只该剩 `instance.lock` + `compression-prefs.json`、`--trace-selftest` 验崩溃清场、`CMI_TRACE_DIR` 隔离测试）；**第七节：发给别人用的 DMG**（`make dmg`、为什么要分两次编译、ad-hoc 签名与 Gatekeeper、`首次打开.command` 干什么、DMG 权限按 a+rX 摆、hdiutil 在沙箱里跑不了）。
- 不用读：日常改业务代码时。

## 文档同步（改完功能顺手做）

- `AGENTS.md` 的「当前进度」写的是**现状**，不是历史；改动如果推翻了某条结论，就地改写，别只在下面追加。
- 每篇 `经验文档/` 开头都有「什么时候读」，新增一节就顺手更新索引描述。
- **核验打包时挑长文案**：≤15 字节的短字符串在 release 产物里搜不到（`关闭` / `下一张` / 菜单标题都是这样，最小值复现见 `经验文档/构建与调试.md` 第二节），别把「grep 不到」当成没打包。
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
- **日常启动的是 `build/cleanmyiphone.app`**，不是 `/Applications` 那份。所以：界面类改动（文案 / 布局 / 逻辑）交付前必须 `./scripts/make-app.sh release` 重新打包，只 `swift build` 用户看不到任何变化（2026-11 踩过，白问了一轮）；核验办法（`LC_ALL=C grep -a` 查新文案进没进二进制、`strings` 对中文无效）见 `经验文档/构建与调试.md` 第二节。不要顺手替换 `/Applications` 里的包。
