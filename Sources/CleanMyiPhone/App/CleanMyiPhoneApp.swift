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
                Button("刷新设备") { Task { await store.startScan() } }
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
    @FocusState private var keyFocus: Bool
    @State private var showSidebar = true
    @State private var showInspector = true

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.18)) { showSidebar.toggle() }
    }

    private func toggleInspector() {
        withAnimation(.easeInOut(duration: 0.16)) { showInspector.toggle() }
    }

    var body: some View {
        @Bindable var store = store

        // 自己排三列：NavigationSplitView 的折叠状态不可控，
        // 出现过"点了按钮不收"的情况，干脆不用它。
        HStack(spacing: 0) {
            if showSidebar && store.previewID == nil {
                MainSidebarView()
                    .frame(width: 236)
                    .transition(.move(edge: .leading))
                Divider()
            }

            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showInspector && store.previewID == nil {
                Divider()
                DeviceInspector()
                    .frame(width: 180)
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(WindowOnScreenGuard())
        .toolbar(removing: .sidebarToggle)
        .environment(\.toggleSidebar, toggleSidebar)
        .environment(\.toggleInspector, toggleInspector)
        .environment(\.sidebarVisible, showSidebar)
        .environment(\.inspectorVisible, showInspector)
        .focusable()
        .focusEffectDisabled()
        .focused($keyFocus)
        .onAppear { keyFocus = true }
        .onKeyPress(keys: AppStore.handledKeys) { press in
            store.handleKey(press)
        }
        // 点过格子之后焦点可能跑到滚动视图上，空格就失效了。
        // 选择一变就把键盘焦点抢回来。
        .onChange(of: store.selection) { _, _ in keyFocus = true }
        .onChange(of: store.previewID) { _, _ in keyFocus = true }
        .onReceive(NotificationCenter.default.publisher(for: .toggleInspector)) { _ in
            toggleInspector()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            toggleSidebar()
        }
        .sheet(isPresented: $store.confirmPresented) {
            ConfirmSheet().environment(store)
        }
        .overlay {
            // 只在「一张都还没有」时盖全屏；目录一到就撤，
            // 剩下的相册库（296 MB）在后台继续读，侧栏照常用「加载中」表示还没好。
            if store.isScanning && store.assets.isEmpty {
                ZStack {
                    Rectangle()
                        .fill(.thickMaterial)
                        .ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text(store.progressText)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity)
            }
        }
        .overlay {
            // 相册索引没读完就整页盖死（左右两栏一起）：这一阶段预览开了也只能干等，
            // 库读完自动撤。暂停态 / 未连接 / 锁屏不盖，那几种情况要能操作。
            if store.needsLibraryGate {
                LibraryIndexGate()
                    .transition(.opacity)
            }
        }
        .overlay {
            if store.previewID != nil {
                PreviewOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: store.needsLibraryGate)
        .animation(.easeInOut(duration: 0.12), value: store.previewID)
        .animation(.easeInOut(duration: 0.16), value: showSidebar)
        .animation(.easeInOut(duration: 0.16), value: showInspector)
    }

    @ViewBuilder
    private var page: some View {
        switch store.section {
        case .overview: OverviewView()
        case .photos: PhotosView()
        case .trash: TrashView()
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
