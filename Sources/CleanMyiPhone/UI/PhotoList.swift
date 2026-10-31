import AppKit
import SwiftUI

struct PhotoList: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            if store.showsDateSections {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(store.assetSections, id: \.id) { section in
                        Section {
                            ForEach(section.assets) { asset in
                                row(asset)
                                Divider().padding(.leading, 52)
                            }
                        } header: {
                            DateHeader(title: section.title, count: section.assets.count)
                        }
                    }
                }
                .padding(.vertical, 4)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.visibleAssets) { asset in
                        row(asset)
                        Divider().padding(.leading, 52)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func row(_ asset: Asset) -> some View {
        let selected = store.selection.contains(asset.id)
        let hovering = store.hoveredID == asset.id
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                if let image = store.thumbnails[asset.id] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 30, height: 30)
                        .clipped()
                } else {
                    Image(systemName: asset.kind.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(asset.fileName)
                .font(.callout)
                .lineLimit(1)

            Text(asset.sizeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()

            if asset.isCloudOnly {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if store.pendingDeletions.contains(asset.id) {
                Image(systemName: "trash.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
            }

            Spacer(minLength: 8)

            Text(asset.dateText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.14)
                             : (hovering ? Color.secondary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .task(id: store.thumbEpoch) { store.requestThumbnail(asset) }
        .onHover { inside in store.setHover(asset.id, active: inside) }
        .onTapGesture {
            // 单击就是勾选 / 取消勾选，累积多选；⇧ 连选
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift) {
                store.extend(to: asset)
            } else {
                store.toggle(asset)
            }
        }
    }
}
