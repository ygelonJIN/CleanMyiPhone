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

    static func normalize(_ name: String) -> String {
        var key = name.lowercased()
        if key.hasPrefix("img_e") { key = "img_" + key.dropFirst(5) }
        return key
    }

    func meta(for fileName: String) -> Meta? {
        metaByFile[Self.normalize(fileName)]
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
    var albums: [Album] = []
    var members: [Int: Set<String>] = [:]
    var generatedAt = Date()

    var isEmpty: Bool { metaByFile.isEmpty }

    // MARK: - 解析

    static func load(dbPath: String) -> PhotoLibraryIndex? {
        guard let db = SQLiteDB(path: dbPath, writable: true), db.quickCheck() else { return nil }
        var index = PhotoLibraryIndex()

        // 资产
        let assetRows = db.rows("""
            SELECT a.Z_PK, a.ZFILENAME, a.ZDIRECTORY, a.ZDATECREATED, a.ZHIDDEN, a.ZFAVORITE,
                   a.ZTRASHEDSTATE, a.ZKIND, a.ZKINDSUBTYPE, a.ZWIDTH, a.ZHEIGHT, a.ZDURATION,
                   b.ZORIGINALFILESIZE AS ZSIZE
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
                resourceBytes: resourceByPK[row.int("Z_PK")] ?? row.int64("ZSIZE")
            )
            let key = Self.normalize(name)
            index.metaByFile[key] = meta
            fileNameByPK[row.int("Z_PK")] = key
            if meta.byteSize > 0 {
                index.metaBySizeDate[Self.sizeDateKey(bytes: meta.byteSize, date: meta.createdAt)] = meta
            }
        }

        // 相簿
        let albumRows = db.rows("""
            SELECT Z_PK, ZTITLE, ZKIND, ZCACHEDCOUNT
            FROM ZGENERICALBUM
            WHERE ZTITLE IS NOT NULL AND TRIM(ZTITLE) <> ''
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
