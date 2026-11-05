import SwiftUI

/// 照片页按 M 展开的「移到相簿」快捷面。
///
/// 2026-11 用户定的口径：
/// - **浮在网格上**（不挤占网格高度），带一层很淡的遮罩；
/// - 面板打开后每本相簿右边才有键帽：`1–9 / 0`、第 11–20 本 `⌥1–⌥0`；
/// - **拖动相簿换位置，第一个位置就是快捷键 1**；
/// - 按一次直接移入，**不需要二次确认**，面板随即收起。
///
/// 顺序只存在内存（`AppStore.albumShortcutOrder`），退出即清空，符合「不留痕」。
struct AlbumShortcutPanel: View {
    @Environment(AppStore.self) private var store

    @State private var showNewAlbumField = false
    @State private var newTitle = ""

    private var fromAlbum: PhotoLibraryIndex.Album? {
        guard let id = store.albumFilter else { return nil }
        return store.libraryAlbums.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if showNewAlbumField { newAlbumRow }
            albumGrid
        }
        .padding(12)
        .frame(maxWidth: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.30), radius: 24, y: 10)
        // 卡片自己吃掉所有点击：不能点到卡片空白处就把下面那层遮罩的「收起」触发掉
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .animation(Motion.pop, value: store.albumShortcutOrder)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("移到相簿")
                    .font(.system(size: 12, weight: .semibold))
                Text(store.selection.isEmpty
                     ? "光标这一张"
                     : "已选 \(store.selection.count) 项")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("拖动相簿换位置 · 第一个位置 = 1")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()

                // 拖乱了想回默认：只影响快捷面，不改相簿浏览栏
                if !store.albumShortcutOrder.isEmpty {
                    Button {
                        store.resetAlbumShortcutOrder()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("恢复默认顺序（张数降序）")
                }

                Button(showNewAlbumField ? "取消新建" : "新建相簿…") {
                    showNewAlbumField.toggle()
                    if !showNewAlbumField { newTitle = "" }
                }
                .controlSize(.small)

                Button {
                    store.albumPanelOpen = false
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("收起（M / Esc）")
            }

            HStack(spacing: 6) {
                Text("按相簿右边的键直接移入，不用再确认")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if let fromAlbum {
                    Text("· 会从「\(fromAlbum.title)」移出")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("只从当前相簿移出") {
                        store.stageMoveShortcutSelection(to: nil)
                        store.albumPanelOpen = false
                    }
                    .controlSize(.small)
                } else {
                    Text("· 只加入相簿")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var newAlbumRow: some View {
        HStack(spacing: 8) {
            TextField("新相簿名", text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit { createAlbumAndMove() }
            Button("新建并移入") { createAlbumAndMove() }
                .controlSize(.small)
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer()
        }
    }

    private var albumGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(store.albumShortcutChoices) { choice in
                    AlbumShortcutChip(
                        choice: choice,
                        shortcut: store.albumShortcutKey(for: choice.id)
                    )
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxHeight: 220)
    }

    private func createAlbumAndMove() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        store.stageNewAlbumAndMove(title: title)
        newTitle = ""
        showNewAlbumField = false
        store.albumPanelOpen = false
    }
}

/// 快捷面里的一颗相簿按钮。
/// 点一下直接移入；**拖动换位置**（拖到谁前面就插到谁前面，拖到第一个就拿到快捷键 1）。
private struct AlbumShortcutChip: View {
    @Environment(AppStore.self) private var store
    let choice: AlbumChoice
    let shortcut: String?

    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            // 常驻的小抓手：告诉用户这一格可以拖
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .help("拖动换位置；第一个位置 = 快捷键 1")

            Image(systemName: choice.isNew
                  ? "rectangle.stack.badge.plus" : "rectangle.stack")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(choice.isNew ? AnyShapeStyle(Color.pink) : AnyShapeStyle(.secondary))

            Text(choice.title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            if choice.isNew {
                Text("待新建")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.pink)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.pink.opacity(0.14)))
                    .fixedSize()
            }

            if let shortcut {
                AlbumShortcutKeyCap(key: shortcut)
            }

            Spacer(minLength: 4)

            Text(choice.isNew
                 ? (choice.count > 0 ? "\(choice.count)" : "—")
                 : "\(choice.count)")
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(targeted ? Color.pink.opacity(0.16) : Color.secondary.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(targeted ? Color.pink.opacity(0.70) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture { move() }
        .draggable(String(choice.id))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let source = Int(raw) else { return false }
            store.moveAlbumShortcut(sourceID: source, to: choice.id)
            return true
        } isTargeted: { targeted = $0 }
        .help(shortcut.map {
            "点一下直接移入「\(choice.title)」；拖动可以换位置（第一个位置 = 快捷键 1），现在按 \($0)"
        } ?? "点一下移入「\(choice.title)」；拖动可以换位置")
        .animation(Motion.pop, value: targeted)
    }

    private func move() {
        store.stageMoveShortcutSelection(to: .init(id: choice.id, title: choice.title))
        store.albumPanelOpen = false
    }
}
