import AppKit
import SwiftUI

/// 全项目**只有这一套**动效常量。以前各处随手写 `easeOut(0.14/0.16/0.18)`，
/// 同一个动作在不同页面的手感都不一样；现在按用途取，改一处全都跟着变。
enum Motion {
    /// 换页：新内容淡入 + 从 0.985 微缩放开
    static let page = Animation.easeOut(duration: 0.85)
    /// 小状态：悬停、底栏文案、进度
    static let fade = Animation.easeOut(duration: 0.30)
    /// 选中 / 标记 / 取消标记：苹果那种弹一下
    static let pop = Animation.spring(response: 0.42, dampingFraction: 0.78)
    /// 弹窗、门禁卡片
    static let sheet = Animation.spring(response: 0.55, dampingFraction: 0.86)
    /// 缩略图到手
    static let thumb = Animation.easeOut(duration: 0.35)
}

extension AnyTransition {
    /// 角标 / 勾 / 叉的进出场：小一号淡入
    static var badge: AnyTransition {
        .scale(scale: 0.55).combined(with: .opacity)
    }
    /// 列表项、格子被删掉时缩着淡出
    static var cellRemove: AnyTransition {
        .scale(scale: 0.92).combined(with: .opacity)
    }
    /// 门禁 / 弹窗内容
    static var dialog: AnyTransition {
        .scale(scale: 0.96).combined(with: .opacity)
    }
}

extension View {
    /// 换页时整块内容淡入 + 微缩。
    ///
    /// `key` 一变就重播（换侧栏、换相簿、切网格/列表）；搜索和筛选**不**触发，
    /// 否则每敲一个字整屏都闪一下。故意不做逐格错峰：
    /// 5000 张的网格一起动就是卡死，整块动一次已经够"不是直接出现"。
    ///
    /// `blocked`：内容还**不该露出来**的时候传 true（概览页在等门禁和首批数据）。
    /// 这时保持完全透明；一旦转成 false 才开始播 —— 这样第一次露出的那一刻
    /// 一定有动画，不会出现"启动进概览页什么都没有、从别的页面切回来才有"。
    func pageReveal(_ key: String, blocked: Bool = false) -> some View {
        modifier(PageRevealModifier(key: key, blocked: blocked))
    }
}

private struct PageRevealModifier: ViewModifier {
    let key: String
    let blocked: Bool

    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.985)
            .onAppear { playIfReady() }
            .onChange(of: blocked) { _, _ in playIfReady() }
            .onChange(of: key) { _, _ in replay() }
    }

    /// 条件满足了就开始播。之前想靠"等窗口上屏"来救启动首屏，
    /// 但 `onAppear` 发生时窗口 `isVisible` 还是 false、等轮询又太晚，
    /// 真正可靠的判据是**内容该不该露**，交给调用方用 `blocked` 说清楚。
    private func playIfReady() {
        guard !blocked, !shown else { return }
        withAnimation(Motion.page) { shown = true }
    }

    private func replay() {
        guard !blocked else { return }
        guard shown else {
            withAnimation(Motion.page) { shown = true }
            return
        }
        // 同一帧里先落回起点再放大等于没动，必须等下一帧。
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { shown = false }
        DispatchQueue.main.async {
            withAnimation(Motion.page) { shown = true }
        }
    }
}
