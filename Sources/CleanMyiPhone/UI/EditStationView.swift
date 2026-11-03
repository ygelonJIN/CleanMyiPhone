import SwiftUI

/// 修改站：**收藏 / 移动相簿 / 新建相簿 全部攒在这儿，一次写回手机。**
///
/// 为什么不能点一下就写（2026-11 真机量过）：改 `Photos.sqlite` 只能整份覆盖，
/// 下 297 MB + 上 297 MB + 重启相册服务，一批 40–60 秒。所以第一次点 ♥ 只记意图，
/// 到这儿点「写回手机」才真动设备 —— 和回收站、压缩站完全同一套规矩。
struct EditStationView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            bottomBar
        }
        .animation(Motion.fade, value: store.edits.count)
        .animation(Motion.fade, value: store.edits.newAlbums.count)
        .task(id: store.edits.count) {
            for entry in store.edits.entries { store.requestThumbnail(entry.asset) }
        }
    }

    // MARK: - 顶栏

    @State private var showNewAlbum = false
    @State private var newAlbumTitle = ""

    private var header: some View {
        PageToolbar {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(!store.edits.hasWork
                     ? "还没有暂存的修改"
                     : "暂存 \(store.edits.count) 项改动 · 写回手机才生效")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if !store.edits.hasWork {
            EmptyStateView(icon: "square.and.pencil",
                           title: "还没有暂存的修改",
                           message: "在照片页点 ♥ 收藏、或者「移动到相簿…」。这些改动只在本机，"
                                 + "到这儿点「写回手机」才真的改到 iPhone 上（一批约 1 分钟）。")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !store.edits.newAlbums.isEmpty {
                        sectionHeader("将新建的相簿")
                        ForEach(store.edits.newAlbums) { album in
                            newAlbumRow(album)
                        }
                        Divider().padding(.vertical, 4)
                    }
                    sectionHeader("待写回的改动")
                    ForEach(store.edits.entries) { entry in
                        row(entry)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func newAlbumRow(_ album: PhotoEditQueue.AlbumRef) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.callout)
                Text("写回时新建这一本（同名不会重复建）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button {
                store.edits.removeNewAlbum(album)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("不建这本了；已经要移进它的照片会退回成「不移动」")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private func row(_ entry: PhotoEditQueue.Entry) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.18))
                if let image = store.thumbnails[entry.asset.id] {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Image(systemName: entry.asset.kind.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.asset.fileName)
                    .font(.callout)
                    .lineLimit(1)
                Text(changeText(entry))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                store.edits.remove(entry.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("撤销这一项（只撤销本机暂存，不动手机）")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    /// 一行说清这张要改什么：`♥ 收藏 · 微信 → 带饭` / `✕ 取消收藏` / `移出 微信`
    private func changeText(_ entry: PhotoEditQueue.Entry) -> String {
        var parts: [String] = []
        if let favorite = entry.favorite {
            parts.append(favorite ? "♥ 收藏" : "♡ 取消收藏")
        }
        if let to = entry.moveTo {
            if let from = entry.moveFrom,
               let fromTitle = store.libraryAlbums.first(where: { $0.id == from })?.title {
                parts.append("\(fromTitle) → \(to.title)")
            } else {
                parts.append("加入「\(to.title)」")
            }
        } else if let from = entry.moveFrom,
                  let fromTitle = store.libraryAlbums.first(where: { $0.id == from })?.title {
            parts.append("移出「\(fromTitle)」")
        }
        return parts.isEmpty ? "（空）" : parts.joined(separator: " · ")
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text(!store.edits.hasWork
                 ? "暂存区是空的"
                 : "共 \(store.edits.count) 项改动"
                   + (store.edits.albumCount > 0 ? " · 新建 \(store.edits.albumCount) 本相簿" : ""))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if store.edits.hasWork {
                Text("一次写回 · 约 1 分钟")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let message = store.provisionalMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 12)

            // 新建一本空相簿：只暂存，写回时才真的建
            Button {
                showNewAlbum = true
            } label: {
                Label("新建相簿", systemImage: "rectangle.stack.badge.plus")
            }
            .controlSize(.small)
            .help("新建一本空相簿（同样只暂存，点「写回手机」才真建）")

            if store.edits.hasWork {
                Button("清空") { store.edits.clear() }
                    .controlSize(.small)
                    .help("只清本机暂存，不动手机")

                Button {
                    Task { await store.submitEdits() }
                } label: {
                    // 压缩在跑时**可以点**：点了就排队，压缩一结束自动写回（用户定的）
                    Label(store.conversionRunning ? "排队写回" : "写回手机",
                          systemImage: "arrow.up.to.line")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(store.editSubmitting || store.isPurging)
                .help(store.conversionRunning
                      ? "正在压缩：点一下排队，压缩跑完会自动写回手机"
                      : "把这一批改动写进 iPhone 的相册库，并让相册重新读取（约 1 分钟）")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background(.bar)
        .alert("新建相簿", isPresented: $showNewAlbum) {
            TextField("相簿名", text: $newAlbumTitle)
            Button("取消", role: .cancel) { newAlbumTitle = "" }
            Button("新建") {
                let title = newAlbumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { _ = store.edits.createAlbum(title: title) }
                newAlbumTitle = ""
            }
        } message: {
            Text("只会写在本机暂存区，点「写回手机」才真的建到 iPhone 上（会多花一次写库）")
        }
    }
}

/// 「移动到相簿…」面板：选一本已有的，或者当场新建一本。
/// **选完只是暂存**，真正写回在修改站里。
struct MoveToAlbumSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var newTitle = ""
    @State private var search = ""

    private var albums: [PhotoLibraryIndex.Album] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        let list = store.libraryAlbums
        guard !needle.isEmpty else { return list }
        return list.filter { $0.title.localizedStandardContains(needle) }
    }

    private var fromAlbum: PhotoLibraryIndex.Album? {
        guard let id = store.albumFilter else { return nil }
        return store.libraryAlbums.first { $0.id == id }
    }

    private var count: Int { store.selection.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("把选中的 \(count) 项移到相簿")
                    .font(.headline)
                if let fromAlbum {
                    Text("会从「\(fromAlbum.title)」里移出")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("只加入相簿，不从别处移出")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                TextField("新建相簿名", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { createAndMove() }
                Button("新建并移入") { createAndMove() }
                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider()

            SearchField(prompt: "搜索相簿", text: $search, width: 200)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(albums) { album in
                        Button {
                            store.stageMoveSelection(to: .init(id: album.id, title: album.title))
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "rectangle.stack")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(album.title)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text("\(album.count) 项")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if albums.isEmpty {
                        Text(search.isEmpty ? "没有相簿" : "没有匹配的相簿")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxHeight: 240)

            Divider()

            HStack {
                if fromAlbum != nil {
                    Button("只从当前相簿移出") {
                        store.stageMoveSelection(to: nil)
                        dismiss()
                    }
                    .help("不加入别的相簿，只把它从「\(fromAlbum?.title ?? "")」拿掉")
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 420, height: 480)
    }

    private func createAndMove() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        store.stageNewAlbumAndMove(title: title)
        dismiss()
    }
}

/// 写回手机的遮罩 / 结果单：**overlay 不是 sheet**（和彻底删除同一套理由：
/// sheet 刚 dismiss 再 present 会被 SwiftUI 顶掉，而且长过程必须盖死整窗）。
struct EditStatusOverlay: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let report = store.editReport {
            reportCard(report)
        } else {
            progressCard
        }
    }

    private var progressCard: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("正在写回手机")
                .font(.system(size: 15, weight: .semibold))
            Text(store.editStageText.isEmpty ? "准备" : store.editStageText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text("整批只写一次相册库，约 1 分钟。别拔线、别锁屏。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    private func reportCard(_ report: EditReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: report.failure == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(report.failure == nil ? .green : .orange)
                Text(report.failure == nil ? "已经改到手机上了" : "没写进去")
                    .font(.system(size: 15, weight: .semibold))
            }

            if let failure = report.failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("改动还留在修改站里，可以直接再点一次「写回手机」。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    line("相簿改动", "\(report.moved) 处")
                    if report.createdAlbums > 0 {
                        line("新建相簿", "\(report.createdAlbums) 本")
                    }
                    line("收藏改动", "\(report.favorited) 处")
                    line("耗时", String(format: "%.0f 秒", report.seconds))
                }
                .font(.callout)
                if !report.ptpBack {
                    Text("照片通道没恢复：拔插一次数据线（删除要用它）。相册里的改动已经生效。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !report.daemonRestarted {
                    Text("相册服务没重启成功：手机上可能还看不到变化，重启一次 iPhone 就生效。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("关闭") { store.dismissEditReport() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).monospacedDigit()
        }
    }
}
