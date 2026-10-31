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

/// 每个页面自己的浮动标题行：和内容同一个左右内边距，不画分隔线、不占一条顶栏
struct DetailHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    /// 二级栏已经显示标题时（照片页），这里就不再重复一遍
    var showTitle: Bool = true
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.sidebarVisible) private var sidebarVisible
    @Environment(\.inspectorVisible) private var inspectorVisible

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                if showTitle {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } else if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 16)
                trailing()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
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

    var body: some View {
        GeometryReader { proxy in
            let total = max(segments.reduce(0) { $0 + $1.value }, 0.0001)
            HStack(spacing: 2) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(segment.color)
                        .frame(width: max(2, proxy.size.width * segment.value / total))
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    var color: Color? = nil
    var highlighted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if let color {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(highlighted ? (color ?? .accentColor) : .clear, lineWidth: 2)
        )
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
