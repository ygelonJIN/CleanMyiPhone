# SwiftUI 版式与崩溃

**什么时候读**：动界面、加图表、改侧栏、遇到闪退或界面乱跳时。

**包含什么**：本机（macOS 27 / Xcode 27 / Swift 6.2 运行时）上踩到的 SwiftUI 崩溃与版式坑，以及"加载中布局乱跳"的根治办法。

**不用读**：只调数据层时不用看。

---

## 一、四个会直接崩溃的坑

1. **`@State` + `@MainActor @Observable` 放在 `App` 上**
   崩溃栈：`swift_getCanonicalPrespecializedGenericMetadata` → `StatePropertyBox.update`。
   改法：`private let store = AppStore()`，不要 `@State`。

2. **`.focusable()` 套在整个页面容器上**
   崩溃栈：`rips_f_BlurRingRoundedDilation` / `__drawnFocusRingBitmapForTime` —— 焦点环绘制时越界。
   改法：`.focusable()` 后面补 `.focusEffectDisabled()`。

3. **`VideoPlayer`（SwiftUI）播放本地视频**
   日志：`failed to demangle superclass of VideoPlayerView from mangled name 'So12AVPlayerViewC'` → `abort()`。
   改法：自己包 `NSViewRepresentable` + AppKit 的 `AVPlayerView`，不要用 `VideoPlayer`。

4. **网格列数在布局期间回写 observable**
   导致约束递归 / 反复重排。改法：`onChange(of: cols)` 里判等后再写，`onAppear` 同理。

## 二、加载中布局乱跳（"无规则移动"）

症状：读取设备时环形卡片和底部卡片不停横竖位移。

原因：**两套高度不同的布局在切换**——有数据时环形占满，无数据时是 240pt 载入卡；而目录是分批回调的，`isScanning`/`hasStats` 在真假间反复翻转，每次切换都触发一次重排；再叠加 `animation(value: assets.count)`，就变成连续抖动。

根治三条：

1. 主区**几何固定**：外层 `GeometryReader` 尺寸不参与切换，只切换里面的内容（载入指示 ↔ 环形）。
2. 底部卡片行给**固定高度**（如 86pt），未就绪时数值显示 `—`，不隐藏组件。
3. 去掉按数据量触发的动画，只在明确的状态切换上加 `animation`。

判断"真实数据到了没有"要用单独的门禁（如 `hasStats = totalCapacity > 0`），不要让 UI 直接读可能为 0 的字段去算百分比。

## 三、环形的画法与手感

- 用 `Circle().trim(from:to:).stroke(...)` 自绘，`.rotationEffect(.degrees(-90))` 从 12 点开始。
- **`lineCap: .butt` + 每段两端各留 ~0.8° 间隙**。用 `.round` 时小分段的圆帽会盖住邻居，看起来就是"重叠"。
- 悬停：`.onContinuousHover` 拿坐标，算 `atan2` 角度 + 半径区间判定落在哪段；命中段 `lineWidth + 3`，其它段 `opacity 0.28`。
- 入场动画：`@State progress` 从 0 到 1，`trim` 的终点乘 `progress`，`withAnimation(.easeOut(duration: 0.7))`。

## 四、版式对齐与自适应的几条习惯

- 页面左右内边距统一成一个值（本项目 18），标题、筛选条、网格左边缘才在同一条线上。
- 缩略图格子用 `Rectangle().aspectRatio(1).overlay { Image.resizable().scaledToFill() }.clipShape(...)`；**图片放在 overlay 里**，它就不参与布局，不会把格子撑破或重叠。
- 侧栏信息面板给**固定高度 + `.clipped()`**，否则截图出现/消失、序列号从空变有值都会推动整个栏。
- 预览覆盖整窗时用 `ZStack { 主界面; if preview { 浮层 } }` 放在 `NavigationSplitView` 外层，并 `.toolbar(visibility, for: .windowToolbar)` 收起窗口工具栏。

## 五、悬停联动（图 ↔ 卡片）

把一个 `hoveredSliceTitle: String?` 放在 store 里：环形 `onHoverTitle` 写入、卡片 `onHover` 写入；两侧都按这个值判断高亮。指向线用卡片的 `overlay(alignment: .top)` 画一条 12pt 竖线 + 5pt 圆点、`offset(y: -17)`，不动布局。

## 六、窗口与主框架（2026-10 重做后）

**不要顶部栏。** 用 `.windowStyle(.hiddenTitleBar)` + 运行期把窗口设成 `fullSizeContentView`、`titleVisibility = .hidden`、`toolbar?.isVisible = false`。红绿灯直接浮在侧栏左上角，侧栏 `List` 用 `.contentMargins(.top, 28, for: .scrollContent)` 让开。

标题和页面按钮放在**内容列自己的浮动标题行**里（`DetailHeader`）：左右内边距和下面卡片一致（18pt），不要放 `NavigationSplitView` 的 toolbar——那会把标题抬到侧栏上方，左右边缘跟内容对不齐。`NavigationSplitView` 自带的侧栏按钮要用 `.toolbar(removing: .sidebarToggle)` 去掉，用自己的 `sidebar.leading` 按钮（走 `NavigationSplitViewVisibility` 绑定）。

侧栏用原生 `List(selection:)` + `Section` + `.badge`，选中项只存一个 `enum SidebarItem`（section / 相簿 / 筛选都从它推出来），不要再同时维护 `section` 和 `filter` 两份状态。

## 七、预览与选择

- 点选只负责「选中」，不碰预览；空格预览的是**鼠标悬停**的那一项（`hoveredID`），没悬停才退回已选。
- 鼠标离开格子时不要立刻清 `hoveredID`：预览层盖上来会触发 leave，清了空格就失效。只在新格子 hover 时覆盖。
- 预览层放在 `NavigationSplitView` 外层（`ZStack` 或 `.overlay`），不要在页面内部再放一份，否则会渲染两层。
- 预览里 ←→ 切项、⏎/S 选中、⌫ 标记 / 取消标记、空格关；**标记和选中都不自动翻页**，状态胶囊当场变就是反馈。预览不改选中集合之外的任何东西。

## 八、环形图悬停与指向线

- 命中判定必须三层都满足：在环带半径内（`outer - lineWidth - 1 … outer + 1`）、角度落在某一段的弧内（扣掉段间 0.45° 的缝）、否则返回 nil。圆环内侧、段缝、圆外、下方卡片都不算悬停。
- 指向线从该段弧中点画到对应卡片的顶部中心：`overlay` 放在最顶层，`.allowsHitTesting(false)`；线 2.5pt + 起点圆点 + 终点箭头 + 白描边阴影。
- 起点坐标：`x = cx + r·sin(θ)`、`y = cy − r·cos(θ)`，θ 从 12 点顺时针；卡片位置用 `GeometryReader` + `PreferenceKey` 收集到同一个命名坐标系里再画。
- 卡片不要自己写 `onHover` 去反写高亮，只由环形的悬停驱动，否则永远有两套状态。

## 九、读取态

- **进度只报「在干什么 + 读了多少字节」，不要报百分比**。百分比是按「目录段 / 库段」两段权重算的，和字节数不同源，卡住时它一动不动反而更可疑（实测停在 32% 十几秒）。
- 读取一定要有收尾路径（`maybeFinishScan` 由目录/相册两个完成条件驱动），再加超时看门狗，避免永远停在「正在读取」。
- 全屏遮罩只在**一张都没有**的时候盖；目录一到就撤，剩下的库在后台读，侧栏用「加载中…」表示还没好。
- 需要"等某个数据就绪才能操作"时（例如库索引没好就不给预览），要**把进度画在页面上**，而不是让用户对着一个没反应的按钮猜。
- **遮罩要盖住侧栏，就必须挂在根视图上**（`RootView` 的 `.overlay`），挂在 `PhotosView` 里只盖得住内容区，左右两栏照样能点。写法：`Rectangle().fill(.thickMaterial).ignoresSafeArea().contentShape(Rectangle())` 铺底、中间一块卡片，整块默认参与命中测试就会吃掉点击。条件用一个计算属性（`store.needsLibraryGate`）收口，把例外一次写清（暂停态要能点「重新读取」、未连接、锁屏），别在视图里东一个 `if`。
- **同一件事只留一层遮罩**：根视图接了全屏门禁之后，原来 `PhotosView` 里那层要收窄成它独有的情况（这里是暂停态），否则两层叠在一起、文案互相打架，也说不清哪一层在拦点击。

## 十、悬停与键盘焦点（2026-11 踩过的坑）

- **悬停怎么做才既显著又像原生**（2026-11 五次改，踩过一次丑的）：一条 **2pt 白 78% 的头发丝边** + **柔和大阴影（radius 14 / y 5 / 34%）** + 里面的图放大 **1.12** + brightness 0.03。显著性靠「浮起来」的阴影和轻微推近。**试过并否决**：「白晕 + 黑边」的双层套框（用户原话「太丑」）、把白环加粗到 3pt。
- **悬停不要用 `.scaleEffect`**：格子被放大后会从鼠标下面"长走"，触发 leave → 收缩 → enter 的循环，手感就是"悬停不灵敏、描边忽有忽无"。要强调就用描边 + 阴影，并给 `.contentShape(Rectangle())` 保证整格都是命中区。
- **鼠标离开格子时不要清 `hoveredID`**（只在新格子 hover 时覆盖）。清了之后空格就变成"没有目标"，表现为"明明悬停过却打不开预览"。
- 点过格子后键盘焦点会跑到 `ScrollView` 上，`.onKeyPress` 收不到按键。修法：`onChange(of: selection)` / `onChange(of: previewID)` 里把 `keyFocus` 抢回根视图。
- 预览层要用**不透明**底色（`.thickMaterial` 或更实），`.ultraThinMaterial` 会让底下的侧栏控件透上来；更稳的做法是预览打开时把左右两侧栏目直接隐藏。

## 十一、别在 body 里做副作用

- **别在 `body` 求值路径上做文件 IO**：`computeVisible()` 里写日志、遍历目录这类操作会被每次重排调用，白白拖慢滚动。
- **别在 view update 期间改被观察的集合**：把 `[Asset.ID: Task]` 这类簿记属性标 `@ObservationIgnored`，否则在 `.onChange` 里改它会把 Observation 的注册表写坏（实测崩溃栈落在 `ObservationRegistrar.registerTracking` / `_NativeSet.resize`）。
- 加载中/进度的数字必须**等宽字体 + 固定宽度**，否则 `1 MB` → `100 MB` 位数变化会把整个卡片撑开、来回跳。

## 十二、动效（2026-11 定的做法）

**常量只放一处**：`UI/Motion.swift` 的 `Motion.page / fade / pop / sheet / reveal / thumb`，加三个转场 `.badge / .cellRemove / .dialog`。以前各处随手写 `easeOut(0.14/0.16/0.18)`，同一种"出现"在三个页面上手感都不一样。

### 12.1 换页淡入：别在同一帧里落回起点
`withAnimation { shown = false }` 紧接着 `withAnimation { shown = true }`，SwiftUI 只会看到最终值，等于没动。要**先无动画落回起点、下一帧再放**：

```swift
var instant = Transaction(); instant.disablesAnimations = true
withTransaction(instant) { shown = false }
DispatchQueue.main.async { withAnimation(Motion.page) { shown = true } }
```

`key` 只放"换页"级别的量（侧栏项 / 相簿 id / 网格↔列表），**搜索和筛选不要算进去**，否则每敲一个字整屏闪一次。

### 12.2 不做逐格错峰
5000 张的网格逐格 `delay(index * 0.01)` = 一次几十秒的连续重绘，直接卡死。整块动一次（淡入 + 0.985→1 微缩）已经够"不是直接出现"。

### 12.3 缩略图到位要淡入
`if let image = …` 这种结构切换不会自己淡入。两头都要给：内容上 `.transition(.opacity)`，容器上 `.animation(Motion.thumb, value: hasThumbnail)`。只给 animation 没有 transition，图还是"啪"地出现。

### 12.4 角标用 scale+opacity 转场
勾 / 垃圾桶 / 叉都是条件渲染，`.transition(.badge)`（`scale 0.55 → 1` + 淡入）配 `Motion.pop`，才像苹果那种"弹出来"，而不是干巴巴地换颜色。

### 12.5 门禁类遮罩：重试期间必须继续盖着
`needsLibraryGate` 只判「库没好 + 不是暂停态 + 不是未连接」。**锁屏也盖**（卡片写"解锁后自动继续读取"），用户点「重新读取」时先清 `isDeviceLocked` 并把 `libraryRetrying` 置真，用 `libraryReadingNow` 决定画进度还是失败卡 —— 否则重试那一瞬间门禁条件为假，界面直接掉回正常页面，用户看到的就是"点了重新读取，界面先进去了"。
### 12.6 「确认弹窗之后还有一段长过程」不要用第二个 sheet
回收站的彻底删除是三段：确认 sheet（`EmptyTrashSheet`）→ 删除中（几十秒）→ 结果单。
后两段**不能用 sheet**，两个坑：

1. **同一个视图上两个 sheet 会打架**：确认 sheet 刚 `dismiss` 就 present 下一个，
   SwiftUI 会把它顶掉 —— 现象是「点了删除，弹窗消失，然后什么都没发生」，用户完全不知道删没删。
2. 删除中必须**盖死整窗**（不许点侧栏、不许按 ⌫ 又去标记一张、不许开预览）。

所以后两段走 `RootView` 的 `.overlay`：`Rectangle().fill(.thickMaterial)` 整窗 + 卡片
（`UI/PurgeStatusOverlay.swift`，和 `LibraryIndexGate` 同一套视觉）。位置**排在预览层之后**，
否则设备卡住时用户还能点到预览。`Group { if progress … else if report … }` 两个分支各自
`.transition(.dialog)`，切分支时自然有弹入。

**遮罩期间的键盘规则**：`handleKeyEvent` 顶部直接拦（那时光标还在，⌫/空格/⌘A 都会误伤），
但 **Esc / ⏎ 必须返回 false 放行** —— 结果单那两个按钮靠 `.keyboardShortcut(.cancelAction)` /
`.defaultAction` 接，`KeyMonitor` 吞掉事件按钮就全废了（`KeyMonitor` 是「返回 true → 事件置 nil」）。

