import SwiftUI

@main
struct CleanMyiPhoneApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate
    private let store: AppStore

    init() {
        // 子进程模式必须在创建 AppStore 之前退出：
        // 否则子进程也会拉 ImageCaptureCore，和它自己的 AFC 抢设备。
        if ProcessInfo.processInfo.arguments.contains("--fetch-library") {
            Probe.runIfRequested()
            exit(0)
        }
        // 单实例：两个 App 进程会各起一个 helper 抢同一条 AFC 通道，
        // 结果就是「相册索引读不出来」。命令行连起两次没有 LaunchServices 拦着。
        guard SingleInstance.acquire() else {
            SingleInstance.activateExisting()
            exit(0)
        }
        Probe.runIfRequested()
        store = AppStore()
    }

    var body: some Scene {
        WindowGroup("cleanmyiphone") {
            RootView()
                .environment(store)
                .task { await store.bootstrap() }
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("刷新设备") { Task { await store.refreshDevice() } }
                    .keyboardShortcut("r")
                Divider()
                Button("连接真机") { store.connectRealDevice() }
                Button("使用模拟设备") { store.useFixture() }
                Divider()
                Button("显示/隐藏侧边栏") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
                Button("设备信息栏") {
                    NotificationCenter.default.post(name: .toggleInspector, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("清空本机数据") { store.purgeLocalData() }
            }
            CommandGroup(after: .toolbar) {
                Button("缩略图") { store.viewMode = .grid }.keyboardShortcut("1")
                Button("列表") { store.viewMode = .list }.keyboardShortcut("2")
            }
        }
    }
}

/// 关掉窗口状态恢复：强制退出后不再弹「要重新打开窗口吗」，
/// 也避免窗口被恢复到不存在的显示器上。
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 先装信号层的清场，再装崩溃栈追踪（后者会覆盖同名 handler，所以它内部也要调 unlink）
        PurgeGuard.install()
        CrashTracer.install()
    }

    /// 退出前清场：不留痕模式开着就连缩略图和相册库快照一起删。
    /// 这是四条退出通路里最正常的一条，其余三条见 `PurgeGuard`。
    func applicationWillTerminate(_ notification: Notification) {
        AppStore.purgeOnTerminate()
    }

    /// 点窗口红点也算「退出」：进程若还留着就不清场，和「不留痕」的约定对不上
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }
}

extension Notification.Name {
    static let toggleInspector = Notification.Name("cmi.toggleInspector")
    static let toggleSidebar = Notification.Name("cmi.toggleSidebar")
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var showSidebar = true
    @State private var showInspector = true

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.4)) { showSidebar.toggle() }
    }

    private func toggleInspector() {
        withAnimation(.easeInOut(duration: 0.36)) { showInspector.toggle() }
    }

    var body: some View {
        @Bindable var store = store

        // 自己排三列：NavigationSplitView 的折叠状态不可控，
        // 出现过"点了按钮不收"的情况，干脆不用它。
        HStack(spacing: 0) {
            // 预览时**不再收起左右两栏**：一收 window 内容区变宽，LazyVGrid 会重排列数，
            // 空格开预览再关掉，底下的网格整体跳一下 —— 用户说的"视图位置会变、
            // 会缩一下、会划走"就是这个。预览层本来就整窗盖死，收不收栏看不出来。
            if showSidebar {
                MainSidebarView()
                    // 左栏定宽 + 最小宽度：窗口再窄也不许把它挤扁或裁掉文字
                    .frame(minWidth: 236, idealWidth: 236, maxWidth: 236)
                    .layoutPriority(2)
                    .transition(.move(edge: .leading))
                Divider()
            }

            // 500 是顶栏要的最小宽度：6 个控件收窄后合计 444 + 左右内边距 36 = 480。
            // 低于这个数顶栏就只能横向滚，"如图标视图/日月年按钮被裁掉"就是这么来的。
            page
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            if showInspector {
                Divider()
                DeviceInspector()
                    // 右栏同样定宽 + 最小宽度
                    .frame(minWidth: 180, idealWidth: 180, maxWidth: 180)
                    .layoutPriority(2)
                    .transition(.move(edge: .trailing))
            }
        }
        // 236 + 1 + 500 + 1 + 180 = 918：窗口最小宽度必须盖住三栏 + 顶栏，
        // 否则顶栏右边那几个控件会被裁掉（2026-11 用户报的就是这个）。
        .frame(minWidth: 920, minHeight: 620)
        .coordinateSpace(name: PreviewAnchorSpace.root)
        .background(WindowOnScreenGuard())
        .toolbar(removing: .sidebarToggle)
        .environment(\.toggleSidebar, toggleSidebar)
        .environment(\.toggleInspector, toggleInspector)
        .environment(\.sidebarVisible, showSidebar)
        .environment(\.inspectorVisible, showInspector)
        // 键盘走窗口级监听（`KeyMonitor`）：不再靠 SwiftUI 焦点，
        // 鼠标点过预览键帽 / 播放器抢走 first responder 之后照样收得到 ⌫ ⏎ 空格 ←→。
        .background(KeyMonitor { event in store.handleKeyEvent(event) })
        .onReceive(NotificationCenter.default.publisher(for: .toggleInspector)) { _ in
            toggleInspector()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            toggleSidebar()
        }
        // 二次确认只剩一处：回收站里的「彻底删除」（真的动设备）
        .sheet(isPresented: $store.emptyTrashConfirmPresented) {
            EmptyTrashSheet().environment(store)
        }
        .overlay {
            // 全流程只用**一个**遮罩组件（`LibraryIndexGate`），而且只有这一层：
            // 1) 相册索引没就绪 —— 任何页面都盖（含概览），点了「重新读取」也继续盖着读；
            // 2) 库好了、照片目录还在枚举 —— 盖到第一批资产出来为止。
            if store.needsLibraryGate {
                LibraryIndexGate()
                    .transition(.opacity)
            } else if store.isScanning, store.assets.isEmpty, !store.needsConnection {
                LibraryIndexGate()
                    .transition(.opacity)
            }
        }
        .overlay {
            if store.previewID != nil {
                // 预览自己的进出场动画（从缩略图长出来 / 缩回去）在 PreviewOverlay 里，
                // 这里不能给 transition：否则会和缩放叠成"缩放 + 淡入"两个动作。
                PreviewOverlay()
                    .transition(.identity)
            }
        }
        // 真删过程中的两块遮罩：删除中 / 删完的结果单。**必须在预览层之后**，
        // 否则设备卡住时用户还能点到预览。这里整块吃掉点击，底下的按钮点不到。
        .overlay {
            if store.purgeProgress != nil || store.purgeReport != nil {
                ZStack {
                    Rectangle()
                        .fill(.thickMaterial)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                    PurgeStatusOverlay()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2),
                   value: store.purgeProgress != nil || store.purgeReport != nil)
        .onChange(of: store.emptyTrashConfirmPresented) { _, shown in
            // 弹窗被 Esc / 点外面关掉时，别把待删名单留在内存里
            if !shown { store.pendingDeleteIDs = [] }
        }
        .animation(.easeInOut(duration: 0.3), value: store.needsLibraryGate)
        .animation(.easeInOut(duration: 0.36), value: showSidebar)
        .animation(.easeInOut(duration: 0.36), value: showInspector)
    }

    @ViewBuilder
    private var page: some View {
        switch store.section {
        case .overview: OverviewView()
        case .photos: PhotosView()
        // 相簿这一节也用照片页：左边挂二级栏（相簿列表），右边是那个相簿里的图
        case .albums: PhotosView()
        case .trash: TrashView()
        case .compression: CompressionView()
        }
    }
}

struct PlaceholderView: View {
    let title: String
    let message: String
    let icon: String

    var body: some View {
        EmptyStateView(icon: icon, title: title, message: message)
            .navigationTitle(title)
    }
}
