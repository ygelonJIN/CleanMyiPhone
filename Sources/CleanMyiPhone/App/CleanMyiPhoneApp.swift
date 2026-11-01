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
        CrashTracer.install()
    }

    /// 退出前清场：不留痕模式开着就连缩略图和相册库快照一起删
    func applicationWillTerminate(_ notification: Notification) {
        AppStore.purgeOnTerminate()
    }

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
            if store.previewID != nil {
                PreviewOverlay()
                    .transition(.opacity)
            }
        }
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
