import SwiftUI
import AppKit

/// 窗口恢复出屏（换过显示器、拔掉外接屏）时自动拉回屏幕中央
struct WindowOnScreenGuard: NSViewRepresentable {
    final class GuardView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                WindowOnScreenGuard.prepare(window)
                WindowOnScreenGuard.ensureOnScreen(window)
                WindowOnScreenGuard.centerIfRequested(window)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                WindowOnScreenGuard.prepare(window)
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        GuardView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// 去掉系统那条标题栏/工具栏：内容顶到窗口最上面，红绿灯直接浮在侧栏上
    static func prepare(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar?.isVisible = false
    }

    /// 调试用：把窗口摆到主屏中央并置前，方便截图/自动化验证
    static func centerIfRequested(_ window: NSWindow) {
        guard ProcessInfo.processInfo.environment["CMI_CENTER_WINDOW"] != nil,
              let screen = NSScreen.main else { return }
        let size = window.frame.size
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                             y: screen.visibleFrame.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func ensureOnScreen(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        let hit = frame.intersection(visible)
        let area = hit.isNull ? 0 : hit.width * hit.height
        if area < frame.width * frame.height * 0.5 {
            let size = NSSize(width: min(frame.width, visible.width - 40),
                              height: min(frame.height, visible.height - 40))
            let origin = NSPoint(x: visible.midX - size.width / 2,
                                 y: visible.midY - size.height / 2)
            window.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        window.makeKeyAndOrderFront(nil)
    }
}

extension View {
    /// List 里只有 >0 才显示系统 badge（0 不占位）
    @ViewBuilder
    func countBadge(_ value: Int) -> some View {
        if value > 0 {
            badge(value)
        } else {
            self
        }
    }
}

/// 读取中：只给系统转圈 + 一句「正在读取…」，不放进度条
struct LoadingState: View {
    var text = "正在读取…"
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// 行内「加载中…」：侧栏计数、页面副标题这些窄位置统一用它。
/// 字体/颜色/省略号都一致，不要各处各写一句。
struct LoadingText: View {
    var text = "加载中…"
    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }
}

/// 圆角搜索框（无原生工具栏时用）
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var width: CGFloat = 160

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
    }
}

/// 缩略图大小：一根小滑杆，左边「密」右边「疏」。
///
/// 2026-11 用户要求：**缩略图不许定死大小**。照片页 / 回收站 / 压缩站三个网格共用
/// `store.thumbCell`（只在网格视图里出现，列表模式没有格子可调）。
/// 宽度钉死 103pt：顶栏宽度是算准的（见 AGENTS.md 的顶栏宽度表），这里不能随字号浮动。
struct ThumbSizeSlider: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Slider(value: Binding(get: { store.thumbCell },
                                  set: { store.setThumbCell($0) }),
                   in: AppStore.thumbCellMin...AppStore.thumbCellMax)
                .controlSize(.mini)
                .frame(width: 70)
                .help("拖动调整缩略图大小（⌘+ 放大 · ⌘- 缩小）")
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 103)
        .help("缩略图大小：\(Int(store.thumbCell)) pt（⌘+ 放大 · ⌘- 缩小）")
    }
}

// MARK: - 无顶部栏的浮动标题行

private struct ToggleSidebarKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var toggleSidebar: () -> Void {
        get { self[ToggleSidebarKey.self] }
        set { self[ToggleSidebarKey.self] = newValue }
    }
}

struct SidebarToggleButton: View {
    var action: () -> Void = {}
    var body: some View {
        Button { action() } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
        .help("显示/隐藏侧边栏（⌃⌘S）")
    }
}

// MARK: - 右侧检查器开关

private struct ToggleInspectorKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var toggleInspector: () -> Void {
        get { self[ToggleInspectorKey.self] }
        set { self[ToggleInspectorKey.self] = newValue }
    }
}

struct InspectorToggleButton: View {
    var action: () -> Void = {}
    var body: some View {
        Button { action() } label: {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
        .help("显示/隐藏设备信息栏（⌥⌘I）")
    }
}

private struct SidebarVisibleKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

private struct InspectorVisibleKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var sidebarVisible: Bool {
        get { self[SidebarVisibleKey.self] }
        set { self[SidebarVisibleKey.self] = newValue }
    }
    var inspectorVisible: Bool {
        get { self[InspectorVisibleKey.self] }
        set { self[InspectorVisibleKey.self] = newValue }
    }
}

/// 顶栏：**没有标题**，一页只有一个控件组，永远正中对齐。
///
/// 2026-11 用户定的规矩：
/// - 所有页面（概览 / 照片 / 相簿 / 回收站）都**不放标题**，原来那行大标题全删；
/// - 控件组**永远居中**，窗口拉宽拉窄都不许往左或往右跑；
/// - 整组 `.fixedSize` 不许被压扁，靠「内容区最小 500 − 左右内边距 36」这条预算保证
///   放得下（见 AGENTS.md 的顶栏宽度表），不再叠一层横向 ScrollView ——
///   那层兜底才是把右侧刷新按钮裁掉的元凶。
struct PageToolbar<Trailing: View>: View {
    /// 整组控件之间的间距统一 8，别每个页面自己定
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Trailing

    var body: some View {
        HStack(spacing: spacing) {
            content()
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .center)
        // 右边多留 4pt：刷新按钮贴着边缘时最容易被裁/被滚动条压住
        .padding(.leading, 18)
        .padding(.trailing, 22)
        .padding(.vertical, 8)
    }
}

/// 预览顶栏 / 照片页快捷键条共用的键帽按钮：**键帽 + 完整文字，整颗都能点**。
/// 样式只有一处定义，两个页面（预览 / 缩略图·列表）不会各长一套。
/// `active` = 这批现在处于「取消…」状态（取消删除 / 取消压缩 / 取消收藏 / 取消移入）。
struct ShortcutKeyButton: View {
    let key: String
    let label: String
    let density: HintDensity
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: density.keyToLabel) {
                Text(key)
                    .font(.system(size: density.keyFont, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: density.keyMinWidth)
                    .padding(.horizontal, density.keyPadding)
                    .padding(.vertical, density.keyPaddingV)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.quaternary)
                    )
                Text(label)
                    .font(.system(size: density.labelFont, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, density.buttonPadding)
            .padding(.vertical, density.buttonPaddingV)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(0.16)
                                 : Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(active ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(key) · \(label)")
    }
}

/// 相簿快捷键的小键帽：相簿栏、预览的「移入相簿」面板、移动面板共用同一颗。
/// `active` = 正在等这个相簿的第二次确认；`onAccent` = 这一行本身是选中态（强调色底）。
struct AlbumShortcutKeyCap: View {
    let key: String
    var active = false
    var onAccent = false

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(active
                             ? AnyShapeStyle(Color.white)
                             : (onAccent ? AnyShapeStyle(Color.white.opacity(0.88))
                                         : AnyShapeStyle(.secondary)))
            .frame(minWidth: 16)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(active
                          ? AnyShapeStyle(Color.pink)
                          : (onAccent ? AnyShapeStyle(Color.white.opacity(0.20))
                                      : AnyShapeStyle(Color.secondary.opacity(0.14))))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(active ? Color.white.opacity(0.35) : .clear, lineWidth: 1)
            )
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.weight(.medium))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// 横向堆叠比例条
struct StackedBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        let label: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 14
    /// 0…1：进场时让每一段从 0 长到真实宽度（概览首屏的"长出来"）
    var progress: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let total = max(segments.reduce(0) { $0 + $1.value }, 0.0001)
            // 段与段之间留 3pt：贴死会看成一根整条，看不出是几块拼起来的
            HStack(spacing: 3) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(segment.color)
                        .frame(width: max(2, proxy.size.width * progress * segment.value / total))
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// 卡片底：14pt 圆角 + 极淡的顶部高光 + 1px 细边 + 很轻的投影。
/// 概览的 6 张卡片和两张排行块都用它，口径一致、不各写一套。
struct CardSurface: ViewModifier {
    var radius: CGFloat = 14
    /// 高亮描边（悬停/联动时才给颜色，平时是透明）
    var border: Color?

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.background.secondary)
                    .overlay {
                        // 自上而下的极淡高光：苹果那种"有一点玻璃感"的卡片
                        LinearGradient(colors: [Color.white.opacity(0.12), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border ?? Color.primary.opacity(0.07), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.06), radius: 7, y: 2)
    }
}

extension View {
    func cardSurface(radius: CGFloat = 14, border: Color? = nil) -> some View {
        modifier(CardSurface(radius: radius, border: border))
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    var color: Color? = nil
    var highlighted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if let color {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color)
                        .frame(width: 10, height: 10)
                        .shadow(color: color.opacity(0.35), radius: 2, y: 1)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 统一最小高度：三行文字（标题/数值/说明）本来就该有这么多，
        // 窗口拉窄、换列数时同一行的卡片不会被压成一条
        .frame(minHeight: 88, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .cardSurface(border: highlighted ? (color ?? .accentColor).opacity(0.75) : nil)
    }
}

/// 设备信息里的一行：左边标签、右边值，值太长中间截断
struct InfoRow: View {
    let label: String
    let value: String
    var muted = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(muted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .help(value)
    }
}

/// 收起一侧栏的小按钮：始终放在它所属的那一栏里
struct CollapseButton: View {
    let symbol: String
    var hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help(hint)
    }
}

/// 窗口级键盘监听：把 keyDown 直接交给 store，**不依赖 SwiftUI 焦点**。
///
/// 为什么不用 `.onKeyPress`：那套要求焦点正好在根视图上。鼠标点过预览里的键帽按钮、
/// 或者播放器拿到 first responder 之后，⌫ / ⏎ 就收不到 —— 用户报的
/// 「预览里按退格没用」就是这个。local monitor 只看窗口，与焦点无关。
///
/// 输入框（搜索框）拿到焦点时**让路**，否则打字会被吞。
struct KeyMonitor: NSViewRepresentable {
    /// 返回 true 表示已处理（事件被吞掉）
    let handle: (NSEvent) -> Bool

    final class MonitorView: NSView {
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
        }

        private func install() {
            remove()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === window else { return event }
                // 正在输入框里打字：一个键都不许抢
                if let responder = window.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return event
                }
                return (self.handle?(event) == true) ? nil : event
            }
        }

        private func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.handle = handle
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.handle = handle
    }
}

/// 相册索引没读完时的全屏遮罩：盖死整个窗口内容区，什么都点不了。
///
/// 三条口径（2026-11）：
/// 1. **任何页面都盖**（概览页也盖），并且**点了「重新读取」之后继续盖着读** ——
///    用户原话「不要先进去再读取」。以前重试时 `libraryStatus` 不清、门禁又被
///    `isDeviceLocked` 关掉，界面就掉回了正常页面。
/// 2. 锁屏不算失败：盖着写「设备已锁屏 / 解锁后自动继续读取」，解锁由
///    `unlockWatch` 探到后自动重读。
/// 3. 只有「没在读 + 有失败原因」才画失败卡；重新读取期间把失败原因留成一行小字。
struct LibraryIndexGate: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.thickMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            content
                .transition(.dialog)
        }
        // 整块吃掉点击：底下侧栏、网格、右栏都点不到
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private var content: some View {
        if store.isDeviceLocked {
            lockedState
        } else if store.libraryReadingNow || store.libraryStatus == nil {
            progressState
        } else if let status = store.libraryStatus {
            failedState(status)
        } else {
            progressState
        }
    }

    /// 锁屏：不是错误，就是得等。自动探测，不用用户回来点「重新读取」。
    private var lockedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.orange)
            VStack(spacing: 3) {
                Text("设备已锁屏")
                    .font(.system(size: 14, weight: .medium))
                Text("解锁 iPhone 后会自动继续读取，不用回来点")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 320)
            }
            ProgressView()
                .progressViewStyle(.linear)
                .frame(width: 320)
        }
        .padding(20)
    }

    /// 读取中的那一屏。
    /// **三行固定**：标题 / 正在读哪个文件 + 已读多少 / 进度条。
    /// 总量要等子进程打出 `SIZE` 才有 —— 那之前进度条走不确定态，两种状态长得一致。
    private var progressState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)

            VStack(spacing: 3) {
                Text(store.libraryRetrying ? "正在重新读取相册索引" : "正在读取相册索引")
                    .font(.system(size: 14, weight: .medium))
                Text(store.libraryFileStage.isEmpty
                     ? "正在等手机回包"
                     : "正在读取 \(store.libraryFileStage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 320)
                Text(byteLine)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 320)
            }

            if store.libraryBytesTotal > 0 {
                ProgressView(value: min(1, Double(store.libraryBytesDone)
                                          / Double(max(store.libraryBytesTotal, 1))))
                    .progressViewStyle(.linear)
                    .frame(width: 320)
            } else {
                // 总量还没到：走不确定态，位置和上面那条一样，不跳
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 320)
            }

            // 重试时把上一次失败的原因留成一行小字：既不闪回失败卡，也不丢掉线索
            if let status = store.libraryStatus {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            } else {
                Text("读完就能浏览与预览（约 8 秒）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .animation(Motion.fade, value: store.libraryRetrying)
    }

    private var byteLine: String {
        let done = AppStore.sizeText(store.libraryBytesDone)
        if store.libraryBytesTotal > 0 {
            return "\(done) / \(AppStore.sizeText(store.libraryBytesTotal))"
        }
        return "已读 \(done)"
    }

    private func failedState(_ status: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
            Text("相册索引没读出来")
                .font(.system(size: 14, weight: .medium))
            Text(status)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
            if store.libraryRetrying {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在重试…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Button("重新读取") {
                Task { await store.retryLibraryNow() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(store.libraryRetrying)
            Text(store.libraryAutoRetryStopped
                 ? "已停止自动重试（连续失败 \(store.libraryFailureCount) 次）。拔插一次数据线、必要时重启 iPhone，再点「重新读取」"
                 : "可以先退出预览面板，插好数据线、解锁手机后再点一次")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 340)
        }
        .padding(20)
    }
}
