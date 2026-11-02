import SwiftUI

/// 回收站真删过程中的两块遮罩：**删除中** 和 **删完的结果单**。
///
/// 为什么不用 `.sheet`：确认弹窗刚 `dismiss` 就立刻 present 下一个 sheet，
/// SwiftUI 会把两个顶掉（现象是"点了删除，弹窗消失、然后什么都没发生"）。
/// 而且删除中必须**盖死整个窗口**（不许点到底下的网格、侧栏、回收站），
/// 所以用 overlay + 厚材质，和项目里的 `LibraryIndexGate` 走同一套做法。
struct PurgeStatusOverlay: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if let progress = store.purgeProgress {
                PurgeProgressCard(progress: progress)
                    .transition(.dialog)
            } else if let report = store.purgeReport {
                PurgeResultCard(report: report)
                    .transition(.dialog)
            }
        }
        .animation(Motion.sheet, value: store.purgeProgress != nil)
        .animation(Motion.sheet, value: store.purgeReport?.id)
    }
}

// MARK: - 删除中

/// 「正在删除」：**这一层存在的意义是让人知道它在动**，不是装饰。
///
/// 以前点完「彻底删除」窗口里没有任何反应（设备删 400 张要几十秒），
/// 用户以为崩了就强退 —— 强退会把内存里的回收站名单丢光。
/// 现在：进度条 + 第几项 + 正在删哪个文件 + 已成功/失败计数 + 一句"别拔线"。
private struct PurgeProgressCard: View {
    let progress: PurgeProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在从 iPhone 删除")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(progress.processed) / \(progress.total)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(.red)

                HStack(spacing: 8) {
                    Text(progress.rangeText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if progress.succeeded > 0 {
                        Text("已删 \(progress.succeeded)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if progress.failed > 0 {
                        Text("· 失败 \(progress.failed)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(progress.currentName.isEmpty ? "正在和设备对账…" : progress.currentName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("删完会逐条告诉你哪些成功、哪些没删掉、为什么。这段时间别拔数据线、别让 iPhone 锁屏；设备 45 秒没回执会自动停下并报原因。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 460)
        .cardSurface()
    }
}

// MARK: - 删完的结果单

private struct PurgeResultCard: View {
    @Environment(AppStore.self) private var store
    let report: PurgeReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: report.hasFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(report.hasFailures ? AnyShapeStyle(.orange) : AnyShapeStyle(.green))
                Text(report.title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                if report.succeededCount > 0 {
                    Text("释放 \(AppStore.sizeText(report.succeededBytes)) · 已从 iPhone 上真正删除")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if report.hasFailures {
                    Text("没删掉的 \(report.failures.count) 项还留在回收站里，可以再试一次。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if report.aborted, report.skipped > 0 {
                    Text("设备中途不再回执，最后 \(report.skipped) 项没有执行 —— 解锁 iPhone 或拔插数据线后再试。")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if report.hasFailures {
                failureList
                // 列表是滚动的、滚动条默认看不见：给一句，别让人以为只删失败了这几条
                if report.failures.count > 3 {
                    Text("列表可以上下滚动，共 \(report.failures.count) 项")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if report.hasFailures {
                    // 有失败才给两个按钮：关掉 / 直接重试（失败项还在回收站里）
                    Button("关闭") { store.dismissPurgeReport() }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)

                    Button {
                        Task { await store.retryFailedPurge() }
                    } label: {
                        Text("重试失败的 \(report.failures.count) 项")
                            .frame(minWidth: 76)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button("好") { store.dismissPurgeReport() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
        .padding(18)
        .frame(width: 520)
        .cardSurface()
    }

    /// 逐条列出：文件名 · 大小 · 原因。失败的项不多时全列，多了只列前 50 条，
    /// 剩下的写一句"还有 N 项"，避免弹窗被撑成一整屏。
    private var failureList: some View {
        let shown = Array(report.failures.prefix(50))
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { failure in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(failure.name)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(AppStore.sizeText(failure.bytes))
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                Text(failure.reason)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 5)
                        if failure.id != shown.last?.id { Divider().opacity(0.5) }
                    }
                    if report.failures.count > shown.count {
                        Text("还有 \(report.failures.count - shown.count) 项没列出来，原因同上")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            // 顶部/底部各留一点：不留的话第一行会贴着圆角被裁掉半截
            .contentMargins(.vertical, 0, for: .scrollContent)
            .frame(maxHeight: 196)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }
}
