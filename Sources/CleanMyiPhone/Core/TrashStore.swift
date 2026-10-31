import Foundation
import Observation

/// 标记式回收站：只存索引，不复制任何文件。
/// 位置：~/Library/Application Support/cleanmyiphone/trash.json
@MainActor
@Observable
final class TrashStore {

    struct Entry: Codable, Identifiable, Hashable {
        let id: String          // Asset.id
        let fileName: String
        let folder: String
        let byteSize: Int64
        let createdAt: Date
        let kindRaw: String
        let deviceID: String
        let markedAt: Date

        var isVideo: Bool { kindRaw == "video" }
    }

    private(set) var entries: [Entry] = []
    private let fileURL: URL
    private var pendingSave: Task<Void, Never>?

    var count: Int { entries.count }
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.byteSize } }
    var ids: Set<Asset.ID> { Set(entries.map(\.id)) }

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cleanmyiphone", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("trash.json")
        load()
    }

    // MARK: - 增删

    func add(_ assets: [Asset], deviceID: String) {
        let now = Date()
        var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for asset in assets {
            byID[asset.id] = Entry(
                id: asset.id,
                fileName: asset.fileName,
                folder: asset.folder,
                byteSize: asset.byteSize,
                createdAt: asset.createdAt,
                kindRaw: asset.kind.rawValue,
                deviceID: deviceID,
                markedAt: now
            )
        }
        entries = byID.values.sorted { $0.markedAt > $1.markedAt }
        scheduleSave()
    }

    func remove(ids: some Sequence<Asset.ID>) {
        let set = Set(ids)
        let before = entries.count
        entries.removeAll { set.contains($0.id) }
        if entries.count != before { scheduleSave() }
    }

    func removeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        scheduleSave()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = entries
        let url = fileURL
        pendingSave = Task { [snapshot, url] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
