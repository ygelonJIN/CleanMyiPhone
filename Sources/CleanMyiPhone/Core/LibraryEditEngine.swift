import Foundation

/// 元数据编辑的**设备侧**：抓库 → 本地改 → 整份写回 → 重启相册服务。
///
/// 和压缩那条路的区别：这里不碰任何照片文件，只改数据库，所以一批的总成本固定在
/// 「297 MB 下 + 297 MB 上 + 重启 assetsd」（实测 40–60 秒）。也正因为这样，
/// **一次只允许一个写库**（`AppStore` 里的 `deviceWriteBusy` 闸门），否则两份整库互相覆盖。
final class LibraryEditEngine: @unchecked Sendable {

    struct Outcome: Sendable {
        var createdAlbums: [Int: Int] = [:]
        var deletedAlbums: [Int] = []
        var favorites = 0
        var memberships = 0
        var daemonRestarted = false
        var elapsed: TimeInterval = 0
        /// 改好的本地库路径（调用方用完负责删）——用来重读索引，免得再下 297 MB
        var editedDBPath: String?
    }

    private let api: MobileDeviceAPI
    private let device: UnsafeMutableRawPointer
    private let afc: UnsafeMutableRawPointer
    private let udid: String
    private let workDir: URL
    private let ownsSession: Bool

    init(udid: String, workDir: URL) throws {
        self.api = try MobileDeviceAPI.shared()
        self.device = try api.firstDevice(timeout: 10)
        self.ownsSession = !api.isSessionOpen
        try api.openSession(device)
        self.afc = try api.openAFC(device)
        self.udid = udid.isEmpty ? api.info(device).identifier : udid
        self.workDir = workDir
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    deinit {
        api.closeAFC(afc)
        if ownsSession { api.stopSession(device) }
    }

    func run(ops: [PhotosDBEdit.Op],
             progress: @escaping (String) -> Void = { _ in }) throws -> Outcome {
        let started = Date()
        var outcome = Outcome()

        let fresh = workDir.appendingPathComponent("fresh", isDirectory: true)
        try? FileManager.default.removeItem(at: fresh)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)

        progress("读取相册库")
        for name in ["Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm"] {
            let remote = "/PhotoData/" + name
            let expected = api.entrySize(afc, path: remote)
            guard expected > 0 else { continue }
            let local = fresh.appendingPathComponent(name)
            let bytes = try api.downloadFile(afc, path: remote, to: local, expected: expected)
            if bytes <= 0, name == "Photos.sqlite" {
                throw NSError(domain: "cmi.edit", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "相册库没读到（设备可能锁屏了）"
                ])
            }
        }
        let base = fresh.appendingPathComponent("Photos.sqlite").path
        guard FileManager.default.fileExists(atPath: base) else {
            throw NSError(domain: "cmi.edit", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "相册库没抓到"
            ])
        }

        progress("修改相册库")
        let (edited, result) = try PhotosDBEdit.apply(dbPath: base, workDir: workDir, ops: ops)
        outcome.createdAlbums = result.createdAlbums
        outcome.deletedAlbums = result.deletedAlbums
        outcome.favorites = result.favorites
        outcome.memberships = result.memberships
        outcome.editedDBPath = edited

        progress("写回手机")
        let data = try Data(contentsOf: URL(fileURLWithPath: edited))
        let temp = "/PhotoData/Photos.sqlite.new"
        try? api.removePath(afc, path: temp)
        let written = try api.writeFile(afc, path: temp, data: data)
        guard written == Int64(data.count) else {
            throw NSError(domain: "cmi.edit", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "写回字节数不对：\(written) / \(data.count)"
            ])
        }
        try api.renamePath(afc, from: temp, to: "/PhotoData/Photos.sqlite")
        // 旧 WAL/SHM 必须删：里面是**旧库**的增量，留着会被当成新库的一部分
        try? api.removePath(afc, path: "/PhotoData/Photos.sqlite-wal")
        try? api.removePath(afc, path: "/PhotoData/Photos.sqlite-shm")

        progress("重启相册服务")
        do {
            try PhotoDaemon.restartLibrary(udid: udid)
            outcome.daemonRestarted = true
        } catch {
            // 库已经写进去了；相册没刷新只是「现在看不到」，重启手机后生效。
            outcome.daemonRestarted = false
            progress("写库成功，但相册没刷新：\(error.localizedDescription)")
        }

        outcome.elapsed = Date().timeIntervalSince(started)
        return outcome
    }
}
