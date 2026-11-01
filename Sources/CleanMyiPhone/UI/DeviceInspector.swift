import SwiftUI

/// 右侧设备信息栏。
///
/// 不用 `List`：macOS 的 sidebar List 会在每行上下各加约 9pt，行距被顶到 33pt，
/// 条目一多（现在 23 行 + 4 个分节）默认 720pt 窗口就放不下、必须滚。
/// 这里改成 ScrollView + VStack，行距由我们自己给：行高 18pt、行间 0pt，
/// 整栏在默认窗口里一次看全。
struct DeviceInspector: View {
    @Environment(AppStore.self) private var store

    @Environment(\.toggleInspector) private var toggle

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                deviceSection
                batterySection
                storageSection
                cellularSection
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
    }

    // MARK: - 分节

    @ViewBuilder
    private var deviceSection: some View {
        section("设备")
        row("名称", store.stats.deviceName.isEmpty ? "—" : store.stats.deviceName)
        row("机型", AppStore.friendlyModel(store.stats.productType).isEmpty
            ? "—" : AppStore.friendlyModel(store.stats.productType))
        row("型号号码", store.stats.modelNumber.isEmpty ? "—" : store.stats.modelNumber)
        row("系统版本", store.stats.productVersion.isEmpty ? "—" : store.stats.productVersion)
        if !store.stats.buildVersion.isEmpty {
            row("构建号", store.stats.buildVersion)
        }
        row("序列号", store.stats.serial.isEmpty ? "—" : store.stats.serial)
        autoRow("激活状态", store.stats.activationState)
        autoRow("芯片架构", store.stats.cpuArchitecture, mono: true)
        if !store.stats.region.isEmpty {
            row("区域", store.stats.region)
        }
        autoRow("时区", store.stats.timeZone)
        row("配对状态", store.stats.isPaired ? "已配对" : "未配对",
            muted: !store.stats.isPaired)
        row("设备状态", store.stats.deviceLocked ? "已锁屏" : "已解锁",
            muted: store.stats.deviceLocked)
        row("设备 ID", store.stats.udid.isEmpty ? "—" : store.stats.udid, mono: true)
        row("连接方式", store.stats.connection)
    }

    @ViewBuilder
    private var batterySection: some View {
        section("电池")
        row("当前电量", store.stats.batteryLevel > 0 ? "\(store.stats.batteryLevel)%" : "—")
        row("充电状态", chargeText)
        // 下面这几项只在这台设备真的给了数据时才出现。
        // 一直挂一行「—」等于告诉用户「我们没做到」，但其实是这条通道没有这个字段。
        if let low = store.stats.lowPowerMode {
            row("低电量模式", low ? "开" : "关")
        }
        if let grade = store.stats.batteryHealthGrade {
            row("健康度分级", grade)
        }
        if let health = store.stats.batteryHealth {
            row("电池健康", String(format: "%.0f%%", health * 100))
        }
        if store.stats.batteryDesign > 0 {
            row("设计最大电量", "\(store.stats.batteryDesign) mAh")
        }
        if store.stats.batteryRawMax > 0 {
            row("有效最大电量", "\(store.stats.batteryRawMax) mAh")
        }
        if store.stats.batteryCycles > 0 {
            row("循环次数", "\(store.stats.batteryCycles) 次")
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        section("存储")
        row("总容量", AppStore.sizeText(store.deviceCapacity))
        row("已用", AppStore.sizeText(store.usedBytes))
        row("可用", AppStore.sizeText(store.freeBytes))
        row("照片", AppStore.sizeText(store.mediaPhotoBytes))
        row("视频", AppStore.sizeText(store.mediaVideoBytes))
        row("回收站", AppStore.sizeText(store.trash.totalBytes))
    }

    @ViewBuilder
    private var cellularSection: some View {
        section("蜂窝")
        row("运营商", store.stats.carrier.isEmpty ? "—" : store.stats.carrier)
    }

    // MARK: - 文案

    /// 充电状态。
    /// 插着线但不在充电是常见情况（电池满了 / 优化充电 / 温度高暂停），
    /// 所以不能把「未充电」和「已插电」并排放在一起 —— 看着像自相矛盾。
    private var chargeText: String {
        if store.stats.batteryCharging { return "充电中" }
        switch store.stats.externalConnected {
        case .some(true):
            return store.stats.fullyCharged == true ? "已插电 · 已充满" : "已插电 · 暂停充电"
        case .some(false):
            return "未充电 · 电池供电"
        case .none:
            return "未充电"
        }
    }

    /// 系统字段：空值统一显示「—」并压成灰色，不出现空白行
    private func autoRow(_ title: String, _ value: String, mono: Bool = false) -> some View {
        row(title, value.isEmpty ? "—" : value, mono: mono, muted: value.isEmpty)
    }

    // MARK: - 行

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 11)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, _ value: String, mono: Bool = false, muted: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                .foregroundStyle(muted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                // 放不下就换行，不省略
                .lineLimit(nil)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        .help(value)
    }
}
