import SwiftUI

/// 预览卡片从哪一格长出来：坐标空间挂在 `RootView` 上。
/// 只有要"从缩略图放大"的那一下用得到，不进任何 preference，免得滚动时重算。
enum PreviewAnchorSpace {
    static let root = "cmi.root"
}

/// 各个内容区自己的坐标空间（框选用）。名字固定，别拼字符串。
enum MarqueeSpace {
    static let grid = "cmi.grid"
    static let list = "cmi.list"
    static let trash = "cmi.trash"
    static let compression = "cmi.compression"
}

/// 这次框选要干什么。**在按下那一刻按"按住的那一格"定死**，
/// 中途不换 —— 否则鼠标划过的状态一变，同一块地方会选中又取消来回跳。
///
/// 只有两种：并入已选 / 取消选中。**没有"取消标记"这一档** ——
/// 取消标记是逐个的人工动作（格子右上角的叉、预览里的 ⌫），
/// 拖一下就把一整片标记撤掉太容易误伤（2026-11 用户定的）。
enum MarqueeMode {
    /// 并入已选（普通框选）
    case select
    /// 按住的那块已经全被选中 → 反过来取消选中
    case deselect
}

/// 收集「每个格子现在在容器里的位置」。
/// 只收**已经实例化出来的格子** —— LazyVGrid 没滚到的本来就没有，
/// 和 Finder 一样，框不到屏幕外的东西。
struct CellFramePreference: PreferenceKey {
    static var defaultValue: [Asset.ID: CGRect] = [:]

    static func reduce(value: inout [Asset.ID: CGRect], nextValue: () -> [Asset.ID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 框选那圈半透明蓝框：macOS 那套做法 —— 直角、1pt 描边、极淡填充。
struct MarqueeRect: View {
    let rect: CGRect

    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.13))
            .overlay(
                Rectangle().strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1)
            )
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }
}

extension View {
    /// 框选：拖出一个矩形，和它相交的格子按当前模式处理。
    ///
    /// 三个要点：
    /// 1. 手势挂在**内容容器**上，坐标用内容自己的 named space ——
    ///    滚动时格子坐标不变，不用重算任何东西。
    /// 2. 模式**在按下那一刻定死**（见 `MarqueeMode`），中途不换。
    /// 3. 只碰「选中」，不碰标记：已标记的项由调用方在 `apply` 里过滤掉。
    ///
    /// macOS 上滚动是 scrollWheel 不是拖拽，所以这个 DragGesture 不会和滚动打架。
    func marqueeSelect(
        in space: String,
        frames: [Asset.ID: CGRect],
        marquee: Binding<CGRect?>,
        isSelected: @escaping (Asset.ID) -> Bool,
        apply: @escaping (Set<Asset.ID>, MarqueeMode) -> Void
    ) -> some View {
        modifier(MarqueeSelectModifier(space: space,
                                       frames: frames,
                                       marquee: marquee,
                                       isSelected: isSelected,
                                       apply: apply))
    }
}

private struct MarqueeSelectModifier: ViewModifier {
    let space: String
    let frames: [Asset.ID: CGRect]
    @Binding var marquee: CGRect?
    let isSelected: (Asset.ID) -> Bool
    let apply: (Set<Asset.ID>, MarqueeMode) -> Void

    @State private var mode: MarqueeMode?

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
                .onChanged { value in
                    let rect = CGRect(
                        x: min(value.startLocation.x, value.location.x),
                        y: min(value.startLocation.y, value.location.y),
                        width: abs(value.location.x - value.startLocation.x),
                        height: abs(value.location.y - value.startLocation.y)
                    )
                    marquee = rect

                    // 按下那一刻矩形是 0 尺寸，稍微放大一点才框得住"按住的那一格"
                    let hitRect = rect.insetBy(dx: -0.5, dy: -0.5)
                    let hits = Set(frames.filter { $0.value.intersects(hitRect) }.keys)
                    guard !hits.isEmpty else { return }

                    if mode == nil { mode = hits.allSatisfy(isSelected) ? .deselect : .select }
                    apply(hits, mode ?? .select)
                }
                .onEnded { _ in
                    marquee = nil
                    mode = nil
                }
        )
    }
}

/// 悬停层：既负责 hover 状态，也顺手把这一格在 root 坐标系里的位置交给调用方
/// （预览卡片要从这里长出来）。位置只在 `onHover` 里读一次、不挂 preference ——
/// 5000 张的网格滚动时一次都不用重算。
struct HoverProbe: View {
    @Binding var hovering: Bool
    /// 参数：是否进入 / 这一格在 root 坐标系里的矩形
    let onHover: (Bool, CGRect) -> Void

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onHover { inside in
                    hovering = inside
                    onHover(inside, geo.frame(in: .named(PreviewAnchorSpace.root)))
                }
        }
    }
}
