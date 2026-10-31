import SwiftUI

/// 右侧设备信息栏：行距压到最小（行高 16、行间 0），字段全展开，放不下就滚。
struct DeviceInspector: View {
    @Environment(AppStore.self) private var store

    @Environment(\.toggleInspector) private var toggle

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(.regularMaterial)
    }

    private var content: some View {
        List {
            Group {
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
                    row("设备 ID", store.stats.udid.isEmpty ? "—" : store.stats.udid, mono: true)
                    row("连接方式", store.stats.connection)

                    section("电池")
                    row("当前电量", store.stats.batteryLevel > 0 ? "\(store.stats.batteryLevel)%" : "—")
                    row("充电状态", store.stats.batteryCharging ? "充电中" : "未充电")
                    row("设计最大电量", store.stats.batteryDesign > 0 ? "\(store.stats.batteryDesign) mAh" : "—")
                    row("有效最大电量", store.stats.batteryRawMax > 0 ? "\(store.stats.batteryRawMax) mAh" : "—")
                    row("电池健康", store.stats.batteryHealth.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                    row("循环次数", store.stats.batteryCycles > 0 ? "\(store.stats.batteryCycles) 次" : "—")
                    row("电池温度", "不可读", muted: true)

                    section("存储")
                    row("总容量", AppStore.sizeText(store.deviceCapacity))
                    row("已用", AppStore.sizeText(store.usedBytes))
                    row("可用", AppStore.sizeText(store.freeBytes))
                    row("照片", AppStore.sizeText(store.mediaPhotoBytes))
                    row("视频", AppStore.sizeText(store.mediaVideoBytes))
                    row("回收站", AppStore.sizeText(store.trash.totalBytes))

                    section("蜂窝与账户")
                    row("运营商", store.stats.carrier.isEmpty ? "—" : store.stats.carrier)
                row("电话号码", "不可读", muted: true)
                row("Apple 账户", "不可读", muted: true)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 12)
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 2, trailing: 0))
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
        .frame(minHeight: 0)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .help(value)
    }
}
