import Foundation

/// 设备照片库索引：把 `Photos.sqlite` 读成相簿、标记与类型。
struct PhotoLibraryIndex {

    struct Meta {
        let fileName: String
        let directory: String
        let createdAt: Date
        let isHidden: Bool
        let isFavorite: Bool
        let isTrashed: Bool
        let isVideo: Bool
        let subtype: Int
        let width: Int
        let height: Int
        let duration: Double
        let byteSize: Int64
        /// 这个资产所有资源（原图 + 编辑渲染版本 + Live Photo 视频分量）的字节合计。
        /// 统计占用必须用它：只看 ZORIGINALFILESIZE 会少算近 30 GB。
        let resourceBytes: Int64
        /// `ZPLAYBACKSTYLE`：1=普通静图、3=实况、4=视频
        let playbackStyle: Int
        /// `ZADDITIONALASSETATTRIBUTES.ZCAMERACAPTUREDEVICE`：1 = 相机拍的（不是从 App 存的）
        let isCameraCaptured: Bool
        /// `ZUNIFORMTYPEIDENTIFIER`：RAW 判定用（`public.adobe.raw-image` 之类）
        let typeIdentifier: String

        /// 实况照片：**两个条件都要**。
        /// 只有 `subtype == 2` 不够 —— 本机实测 1939 条 subtype=2 里有 4 条
        /// `playbackStyle = 1`（拍的时候把实况关了），那 4 条没有视频分量，不算实况。
        var isLive: Bool { !isVideo && subtype == 2 && playbackStyle == 3 }

        /// RAW：认设备报的类型标识，退化时看扩展名
        var isRaw: Bool {
            if typeIdentifier.contains("raw-image") { return true }
            return Self.rawExtensions.contains((fileName as NSString).pathExtension.lowercased())
        }

        static let rawExtensions: Set<String> = [
            "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "srw", "pef", "3fr"
        ]
    }

    struct Album: Identifiable, Hashable {
        let id: Int
        let title: String
        let kind: Int
        let count: Int
    }

    /// 归一化后的文件名：小写；编辑版 `IMG_E1234` 归到 `IMG_1234`
    var metaByFile: [String: Meta] = [:]
    /// 按「体积 + 拍摄时间(秒)」建的第二索引：PTP 的名字和磁盘名对不上时用
    private var metaBySizeDate: [String: Meta] = [:]
    /// 数字后缀索引：`img_7329.jpg` → "7329" → [归一化文件名]。
    /// 查询必须走这张预建表 —— 在查询里现扫 `metaByFile` 就是 O(n)，
    /// 而 `meta()` 对每张资产都会被调（`tagSet` / `computeVisible` / 侧栏统计），
    /// 5000 张 × 5000 条字符串过滤 ≈ 2700 万次，实测直接把界面卡死几分钟。
    private var fileNameByDigits: [String: [String]] = [:]
    /// 拍摄时间索引（到秒）：`PTP 名字随机 + 体积也对不上`时的最后一道匹配。
    /// 视频的 PTP `byteSize` 长期不准，只靠「体积 + 时间」那层基本全 miss。
    private var metaBySecond: [Int: [Meta]] = [:]

    static func normalize(_ name: String) -> String {
        var key = name.lowercased()
        if key.hasPrefix("img_e") { key = "img_" + key.dropFirst(5) }
        return key
    }

    /// 诊断用：时间索引里到底装了多少东西（0 就说明根本没建起来）
    var timeIndexCoverage: (seconds: Int, assets: Int) {
        (metaBySecond.count, metaBySecond.values.reduce(0) { $0 + $1.count })
    }

    func meta(for fileName: String) -> Meta? {
        metaByFile[Self.normalize(fileName)]
    }

    /// PTP 名字是随机的（`HPQE7329.MP4` ↔ `IMG_7329.MP4` 连数字都对不上）时，
    /// 只剩拍摄时间可用：在 ±2 秒窗口里找**同种类**资产，**唯一命中**才算。
    /// 不唯一（连拍、批量导入同一秒）就返回 nil，宁可退到慢路也不猜错。
    func meta(matchingTimeOf date: Date, isVideo: Bool) -> Meta? {
        let base = Int(date.timeIntervalSinceReferenceDate.rounded())
        var hits: [Meta] = []
        for offset in -2...2 {
            if let list = metaBySecond[base + offset] { hits.append(contentsOf: list) }
        }
        var seen = Set<String>()
        let unique = hits.filter {
            $0.isVideo == isVideo && seen.insert(Self.normalize($0.fileName)).inserted
        }
        return unique.count == 1 ? unique[0] : nil
    }

    static func sizeDateKey(bytes: Int64, date: Date) -> String {
        "\(bytes)-\(Int(date.timeIntervalSinceReferenceDate.rounded()))"
    }

    /// 名字对不上时，用体积 + 前后 2 秒的拍摄时间找
    func meta(matching bytes: Int64, date: Date) -> Meta? {
        guard bytes > 0 else { return nil }
        for offset in stride(from: -2, through: 2, by: 1) {
            let shifted = date.addingTimeInterval(TimeInterval(offset))
            if let hit = metaBySizeDate[Self.sizeDateKey(bytes: bytes, date: shifted)] { return hit }
        }
        return nil
    }

    /// PTP 报的名字和磁盘名对不上时再用一层：按**数字后缀 + 同扩展名**找。
    /// 例：PTP 给 `HPQE7329.MP4`，磁盘上是 `IMG_7329.MP4`。
    /// 要求唯一命中 —— 撞了两个就不猜，交给名字匹配那条路。
    /// 走预建的 `fileNameByDigits`，只看候选，不扫全库。
    func meta(matchingDigitsOf fileName: String) -> Meta? {
        let digits = fileName.filter(\.isNumber)
        guard digits.count >= 3, let keys = fileNameByDigits[digits] else { return nil }
        let ext = (fileName as NSString).pathExtension.lowercased()
        var hit: Meta?
        for key in keys {
            guard ext.isEmpty || (key as NSString).pathExtension.lowercased() == ext else { continue }
            if hit != nil { return nil }
            hit = metaByFile[key]
        }
        return hit
    }
    var albums: [Album] = []
    var members: [Int: Set<String>] = [:]
    var generatedAt = Date()
    /// 库里有、但 PTP 没枚举出来的资产（已隐藏 / 最近删除 / iCloud 优化项 / App 存的随机名）。
    /// 这些页面只能靠它，否则侧栏说有 124 张、点进去却是空的。
    var shadowAssets: [Asset] = []
    /// 库里的**每一行**（不做文件名去重）。`metaByFile` 是按归一化文件名做键的，
    /// 两个不同目录下的同名文件会互相覆盖 —— 侧栏统计必须用这一份，否则少算。
    var allMeta: [Meta] = []

    var isEmpty: Bool { metaByFile.isEmpty }

    // MARK: - 解析

    static func load(dbPath: String) -> PhotoLibraryIndex? {
        guard let db = SQLiteDB(path: dbPath, writable: true), db.quickCheck() else { return nil }
        var index = PhotoLibraryIndex()

        // 资产
        let assetRows = db.rows("""
            SELECT a.Z_PK, a.ZFILENAME, a.ZDIRECTORY, a.ZDATECREATED, a.ZHIDDEN, a.ZFAVORITE,
                   a.ZTRASHEDSTATE, a.ZKIND, a.ZKINDSUBTYPE, a.ZWIDTH, a.ZHEIGHT, a.ZDURATION,
                   a.ZPLAYBACKSTYLE, a.ZUNIFORMTYPEIDENTIFIER,
                   b.ZORIGINALFILESIZE AS ZSIZE,
                   b.ZCAMERACAPTUREDEVICE AS ZCAMCAPTURED
            FROM ZASSET a
            LEFT JOIN ZADDITIONALASSETATTRIBUTES b ON b.ZASSET = a.Z_PK
            """)

        // 资源表：每个资产可能有多份（原图 / 编辑版本 / 视频分量）
        var resourceByPK: [Int: Int64] = [:]
        for row in db.rows("SELECT ZASSET AS asset, SUM(ZDATALENGTH) AS total FROM ZINTERNALRESOURCE GROUP BY ZASSET") {
            let pk = row.int("asset")
            guard pk > 0 else { continue }
            resourceByPK[pk] = row.int64("total")
        }

        var fileNameByPK: [Int: String] = [:]
        for row in assetRows {
            guard let name = row.string("ZFILENAME"), !name.isEmpty else { continue }
            let meta = Meta(
                fileName: name,
                directory: row.string("ZDIRECTORY") ?? "",
                createdAt: Date(timeIntervalSinceReferenceDate: row.double("ZDATECREATED")),
                isHidden: row.int("ZHIDDEN") == 1,
                isFavorite: row.int("ZFAVORITE") == 1,
                isTrashed: row.int("ZTRASHEDSTATE") == 1,
                isVideo: row.int("ZKIND") == 1,
                subtype: row.int("ZKINDSUBTYPE"),
                width: row.int("ZWIDTH"),
                height: row.int("ZHEIGHT"),
                duration: row.double("ZDURATION"),
                byteSize: row.int64("ZSIZE"),
                resourceBytes: resourceByPK[row.int("Z_PK")] ?? row.int64("ZSIZE"),
                playbackStyle: row.int("ZPLAYBACKSTYLE"),
                isCameraCaptured: row.int("ZCAMCAPTURED") == 1,
                typeIdentifier: row.string("ZUNIFORMTYPEIDENTIFIER") ?? ""
            )
            let key = Self.normalize(name)
            index.allMeta.append(meta)
            index.metaByFile[key] = meta
            fileNameByPK[row.int("Z_PK")] = key
            if meta.byteSize > 0 {
                index.metaBySizeDate[Self.sizeDateKey(bytes: meta.byteSize, date: meta.createdAt)] = meta
            }
            // 数字后缀索引：建一次，之后每次查询都不用扫全库
            let digits = key.filter(\.isNumber)
            if digits.count >= 3 {
                index.fileNameByDigits[digits, default: []].append(key)
            }
            // 拍摄时间索引：PTP 名字随机、体积又不准时，靠它兜底
            let second = Int(meta.createdAt.timeIntervalSinceReferenceDate.rounded())
            index.metaBySecond[second, default: []].append(meta)
        }

        // 影子资产：库里有、PTP 不一定枚举得到的那些（已隐藏 / 最近删除 / 云端项）
        index.shadowAssets = index.metaByFile.map { key, meta in
            Asset(
                id: "lib|\(key)",
                fileName: meta.fileName,
                folder: meta.directory,
                byteSize: meta.byteSize > 0 ? meta.byteSize : meta.resourceBytes,
                createdAt: meta.createdAt,
                kind: meta.isVideo ? .video : .photo,
                tags: [],
                pixelWidth: meta.width,
                pixelHeight: meta.height,
                duration: meta.duration
            )
        }
        index.shadowAssets.sort { $0.createdAt < $1.createdAt }

        // 相簿。
        // 排除两类**不是相簿**的行：
        //   1. `ZKIND` 3571/3572/3573 = 系统进度占位（标题 `progress-sync` / `progress-ota-restore` /
        //      `progress-fs-import`），本机实测确实存在，显示出来就是三个 0 张的空相簿；
        //   2. 其余没有标题的行（智能相簿 `FetchingAlbum`、导入会话、共享相簿占位）——
        //      智能相簿的成员是运行期算的，库里没有，列出来点进去永远是空。
        let albumRows = db.rows("""
            SELECT Z_PK, ZTITLE, ZKIND, ZCACHEDCOUNT
            FROM ZGENERICALBUM
            WHERE ZTITLE IS NOT NULL AND TRIM(ZTITLE) <> ''
              AND ZKIND NOT IN (3571, 3572, 3573)
              AND ZTITLE NOT LIKE 'progress-%'
            """)
        var albums: [Album] = []
        for row in albumRows {
            albums.append(Album(
                id: row.int("Z_PK"),
                title: row.string("ZTITLE") ?? "未命名相簿",
                kind: row.int("ZKIND"),
                count: row.int("ZCACHEDCOUNT")
            ))
        }

        // 关联表：不同 iOS 版本表名会变，按列名模式探测
        for table in db.tables(matching: "Z_%ASSETS") {
            let cols = db.columns(of: table)
            guard let albumCol = cols.first(where: { $0.hasSuffix("ALBUMS") }),
                  let assetCol = cols.first(where: { $0.hasSuffix("ASSETS") && $0 != albumCol })
            else { continue }

            let joins = db.rows("SELECT \(albumCol) AS album, \(assetCol) AS asset FROM \(table)")
            guard !joins.isEmpty else { continue }

            var members: [Int: Set<String>] = [:]
            for row in joins {
                let albumID = row.int("album")
                guard albumID > 0, let name = fileNameByPK[row.int("asset")] else { continue }
                members[albumID, default: []].insert(name)
            }
            // 只接受"能对上相簿"的那张关联表
            let albumIDs = Set(albums.map(\.id))
            let matched = members.keys.filter { albumIDs.contains($0) }
            guard !matched.isEmpty else { continue }

            index.albums = albums.map { album in
                Album(id: album.id, title: album.title, kind: album.kind,
                      count: members[album.id]?.count ?? album.count)
            }
            index.members = members
            break
        }

        if index.albums.isEmpty {
            index.albums = albums
        }
        return index
    }

    // MARK: - 查询

    func albumsSorted() -> [Album] {
        albums.sorted { $0.count > $1.count }
    }

    func files(inAlbum id: Int) -> Set<String> {
        members[id] ?? []
    }
}
