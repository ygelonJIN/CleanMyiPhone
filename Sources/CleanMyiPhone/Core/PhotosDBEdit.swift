import Foundation

/// 元数据编辑：直接改 `Photos.sqlite`（收藏 / 相簿成员 / 新建相簿）。
///
/// 为什么单独一个文件：压缩那条路的 `ConversionDB` 做的是「复制一行资产、改像素尺寸」，
/// 相簿和收藏用不上；这里只做「改几位、加删几行关联」。
///
/// 两条必守的规矩（和 `PhotoLibraryIndex` 读侧同一套）：
/// 1. **不写死表名 / 列名**：关联表名随 iOS 版本变（本机 `Z_33ASSETS`），列名也变；
/// 2. **不写死列集**：新建相簿用「复制一行现有用户相簿、再改 PK / 标题」的办法，
///    未知的 NOT NULL 列、`Z_OPT`、`ZPARENTFOLDER` 全都跟着模板走。
///
/// 这个类型只负责「把一份本地库改对」，**不碰设备**：下载、上传、重启相册服务
/// 在调用方（压缩走 `PhotoConversionEngine`，元数据编辑走 `LibraryWriteback`）。
enum PhotosDBEdit {

    enum Op {
        case favorite(pk: Int, value: Bool)
        case createAlbum(tempID: Int, title: String)
        case membership(assetPK: Int, album: AlbumTarget, present: Bool)
        /// 删相簿：成员关联、封面记录、相簿行一起清。`Z_PRIMARYKEY` 不回收（PK 留空洞是正常的）。
        case deleteAlbum(pk: Int)
    }

    /// 目标相簿：已经存在的，或这一批里刚建的（用临时 ID 引用，建完再换成真 PK）。
    enum AlbumTarget {
        case existing(Int)
        case created(Int)
    }

    struct Result {
        var createdAlbums: [Int: Int] = [:]
        var deletedAlbums: [Int] = []
        var favorites = 0
        var memberships = 0
        var affectedAlbums: Set<Int> = []
        /// 找不到的资产（批次期间被删了）——跳过，不算失败。
        var missingAssets: [Int] = []
    }

    enum EditError: LocalizedError {
        case sql(String)
        case missingTable(String)
        case missingTemplateAlbum
        case missingPrimaryKey(String)
        case verifyFailed

        var errorDescription: String? {
            switch self {
            case .sql(let what): return "改库失败：\(what)"
            case .missingTable(let what): return "库里找不到 \(what)"
            case .missingTemplateAlbum: return "库里没有可以当模板的用户相簿（`ZGENERICALBUM` 一行都没有）"
            case .missingPrimaryKey(let name): return "`Z_PRIMARYKEY` 里没有 \(name)"
            case .verifyFailed: return "改完 quick_check 不通过"
            }
        }
    }

    /// 相簿 ↔ 资产关联表。列名不写死，按后缀探测。
    struct JoinTable {
        let name: String
        let albumColumn: String
        let assetColumn: String
    }

    // MARK: - 入口

    /// 在 `dbPath` 的副本上应用这一批编辑，返回改好的库路径。
    ///
    /// `ops` 里可以混着三种操作；执行顺序是 **建相簿 → 收藏 → 成员关系**（后者要引用新 PK）。
    /// 同一个资产上重复的收藏/成员操作由调用方（队列）先收敛，这里按顺序照做。
    static func apply(dbPath: String,
                      workDir: URL,
                      ops: [Op],
                      now: Date = Date()) throws -> (path: String, result: Result) {
        let fm = FileManager.default
        let dir = workDir.appendingPathComponent("edit", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let work = dir.appendingPathComponent("Photos.sqlite")

        for suffix in ["", "-wal", "-shm"] {
            let source = dbPath + suffix
            guard fm.fileExists(atPath: source) else { continue }
            try fm.copyItem(atPath: source, toPath: work.path + suffix)
        }

        guard let db = SQLiteDB(path: work.path, writable: true) else {
            throw EditError.sql("打不开 \(work.path)")
        }
        guard db.run("PRAGMA wal_checkpoint(TRUNCATE);") else {
            throw EditError.sql("wal_checkpoint")
        }
        _ = db.run("PRAGMA journal_mode=DELETE;")

        let join = try joinTable(db)

        // CoreData 的触发器要调 `NSCoreData...` 函数，纯 sqlite3 没有 —— 先摘掉、改完装回去。
        let touched = ["ZASSET", "ZGENERICALBUM", join.name]
        let triggers = db.rows("""
            SELECT name, sql FROM sqlite_master
            WHERE type='trigger' AND tbl_name IN (\(touched.map(quote).joined(separator: ", ")))
            """)
        for trigger in triggers {
            guard let name = trigger.string("name") else { continue }
            _ = db.run("DROP TRIGGER IF EXISTS \(identifier(name));")
        }

        var result = Result()

        // 1. 建相簿（先做：后面的成员关系要引用新 PK）
        for case let .createAlbum(tempID, title) in ops {
            let real = try createAlbum(db, tempID: tempID, title: title, now: now)
            result.createdAlbums[tempID] = real
            result.affectedAlbums.insert(real)
        }

        // 1.5 删相簿：成员、封面、相簿行一起清
        for case let .deleteAlbum(pk) in ops {
            _ = db.run("DELETE FROM \(identifier(join.name)) WHERE \(identifier(join.albumColumn)) = \(pk);")
            for table in db.tables(matching: "Z_%KEYASSETS") {
                let cols = db.columns(of: table)
                if let albumCol = cols.first(where: { $0.hasSuffix("ALBUMSBEINGKEYASSETS") }) {
                    _ = db.run("DELETE FROM \(identifier(table)) WHERE \(identifier(albumCol)) = \(pk);")
                }
            }
            guard db.run("DELETE FROM ZGENERICALBUM WHERE Z_PK = \(pk);") else {
                throw EditError.sql("删相簿 \(pk)")
            }
            result.deletedAlbums.append(pk)
            result.affectedAlbums.remove(pk)
        }

        // 2. 收藏
        for case let .favorite(pk, value) in ops {
            guard assetExists(db, pk: pk) else {
                result.missingAssets.append(pk)
                continue
            }
            guard db.run("UPDATE ZASSET SET ZFAVORITE=\(value ? 1 : 0) WHERE Z_PK=\(pk);") else {
                throw EditError.sql("更新收藏 \(pk)")
            }
            result.favorites += 1
        }

        // 3. 相簿成员
        for case let .membership(assetPK, target, present) in ops {
            let album: Int
            switch target {
            case .existing(let id):
                album = id
            case .created(let temp):
                guard let id = result.createdAlbums[temp] else {
                    throw EditError.sql("成员关系引用了没建成的相簿 \(temp)")
                }
                album = id
            }
            guard assetExists(db, pk: assetPK) else {
                if !result.missingAssets.contains(assetPK) { result.missingAssets.append(assetPK) }
                continue
            }
            try setMembership(db, join: join, assetPK: assetPK, album: album, present: present)
            result.memberships += 1
            result.affectedAlbums.insert(album)
        }

        // 4. 计数（设备自己会不会重算不知道，写对更稳）
        for album in result.affectedAlbums {
            refreshCounts(db, join: join, album: album)
        }

        for trigger in triggers {
            guard let sql = trigger.string("sql") else { continue }
            _ = db.run(sql)
        }
        // 触发器必须原样装回去：装丢了，设备那边的 CoreData 会当成另一套库行为。
        let restored = db.rows("""
            SELECT COUNT(*) AS c FROM sqlite_master
            WHERE type='trigger' AND tbl_name IN (\(touched.map(quote).joined(separator: ", ")))
            """).first?.int("c") ?? 0
        guard restored == triggers.count else {
            throw EditError.sql("触发器没装回去（\(restored)/\(triggers.count)）")
        }

        guard db.quickCheck() else { throw EditError.verifyFailed }
        return (work.path, result)
    }

    // MARK: - 关联表探测

    /// 扫 `Z_%ASSETS`，找列名以 `ALBUMS` / `ASSETS` 结尾、且能对上 `ZGENERICALBUM.Z_PK` 的那张。
    static func joinTable(_ db: SQLiteDB) throws -> JoinTable {
        for table in db.tables(matching: "Z_%ASSETS") {
            let cols = db.columns(of: table)
            guard let albumCol = cols.first(where: { $0.hasSuffix("ALBUMS") }),
                  let assetCol = cols.first(where: { $0.hasSuffix("ASSETS") && $0 != albumCol })
            else { continue }
            let hits = db.rows("""
                SELECT COUNT(*) AS c FROM \(identifier(table)) j
                JOIN ZGENERICALBUM a ON a.Z_PK = j.\(identifier(albumCol))
                """).first?.int("c") ?? 0
            if hits > 0 {
                return JoinTable(name: table, albumColumn: albumCol, assetColumn: assetCol)
            }
        }
        throw EditError.missingTable("相簿关联表（`Z_%ASSETS` 里没有能和 ZGENERICALBUM 对上的）")
    }

    // MARK: - 建相簿

    /// 建一个新相簿。做法是**复制一行现成的用户相簿**，再把「身份 / 时间 / 排序 / 来源」这些
    /// 逐列改成新的。
    ///
    /// ⚠️ 2026-11 真机踩过的坑：第一版从「PS App」那一行复制（`ZKIND=2 ORDER BY Z_PK LIMIT 1`
    /// 正好挑到它），相簿**在手机上出现了但里面是空的** —— 复制过来的
    /// `ZIMPORTEDBYBUNDLEIDENTIFIER=com.playstation…`、`ZSTARTDATE/ZENDDATE`、`Z_OPT=500`、
    /// `ZCUSTOMSORTKEY=0`、和 PS App 撞同一个 `Z_FOK_PARENTFOLDER`，全是「来源 App 相簿」的痕迹。
    /// 所以模板要挑**用户自己建的**（来源是 `com.apple.mobileslideshow.photospicker`）。
    private static func createAlbum(_ db: SQLiteDB, tempID: Int, title: String, now: Date) throws -> Int {
        let base = """
            SELECT Z_PK FROM ZGENERICALBUM
            WHERE ZKIND = 2 AND ZTITLE IS NOT NULL AND TRIM(ZTITLE) <> ''
              AND ZTITLE NOT LIKE 'progress-%'
            """
        // 优先级：用户自己建的 → 任意 ZKIND=2 → 任意有标题的
        let template = db.rows(base + """
              AND ZIMPORTEDBYBUNDLEIDENTIFIER = 'com.apple.mobileslideshow.photospicker'
            ORDER BY Z_PK DESC LIMIT 1
            """).first?.int("Z_PK")
            ?? db.rows(base + " ORDER BY Z_PK DESC LIMIT 1").first?.int("Z_PK")
            ?? db.rows("""
                SELECT Z_PK FROM ZGENERICALBUM
                WHERE ZTITLE IS NOT NULL AND TRIM(ZTITLE) <> '' AND ZTITLE NOT LIKE 'progress-%'
                ORDER BY Z_PK DESC LIMIT 1
                """).first?.int("Z_PK")
        guard let template, template > 0 else { throw EditError.missingTemplateAlbum }

        // `Z_PRIMARYKEY.Z_NAME` 存的是 CoreData **实体名**，不保证等于表名：
        // 本机实测库里根本没有 `ZGENERICALBUM` 这个值（第一次真机跑就报这句）。
        // 所以按「名字候选 → 实体名含 ALBUM → Z_MAX 装得下这张表最大 PK」三级往下退。
        let maxAlbumPK = db.rows("SELECT MAX(Z_PK) AS c FROM ZGENERICALBUM").first?.int("c") ?? 0
        guard let entity = entityRow(db, tableMaxPK: max(0, maxAlbumPK)) else {
            throw EditError.missingPrimaryKey("ZGENERICALBUM")
        }
        let newPK = max(entity.max, maxAlbumPK, template) + 1

        _ = db.run("DROP TABLE IF EXISTS cmi_album;")
        guard db.run("CREATE TEMP TABLE cmi_album AS SELECT * FROM ZGENERICALBUM WHERE Z_PK=\(template);") else {
            throw EditError.sql("复制相簿行 \(template)")
        }

        let cols = db.columns(of: "ZGENERICALBUM")
        var sets = ["Z_PK=\(newPK)", "ZTITLE=\(quote(title))"]

        // UUID：正常用户相簿是**带横线的大写 UUID 字符串**；blob 就按 16 字节给。
        if cols.contains("ZUUID") {
            let kind = db.rows("SELECT typeof(ZUUID) AS t FROM ZGENERICALBUM WHERE Z_PK=\(template)")
                .first?.string("t") ?? "text"
            if kind == "blob" {
                sets.append("ZUUID=x'\(randomHex(16))'")
            } else if kind == "text" {
                sets.append("ZUUID=\(quote(UUID().uuidString.uppercased()))")
            }
        }
        for col in ["ZCACHEDCOUNT", "ZCACHEDPHOTOSCOUNT", "ZCACHEDVIDEOSCOUNT", "ZCACHEDBURSTCOUNT"]
        where cols.contains(col) {
            sets.append("\(col)=0")
        }
        let stamp = now.timeIntervalSinceReferenceDate
        for col in ["ZCREATIONDATE", "ZMODIFICATIONDATE", "ZADDEDDATE", "ZLASTMODIFIEDDATE",
                    "ZSTARTDATE", "ZENDDATE"] where cols.contains(col) {
            sets.append("\(col)=\(stamp)")
        }
        // 版本号：新对象就是 1，别继承模板那些几百次的同步计数
        if cols.contains("Z_OPT") { sets.append("Z_OPT=1") }
        // 手动排序键：每本加一，别和模板撞
        if cols.contains("ZCUSTOMSORTKEY") {
            let next = (db.rows("""
                SELECT IFNULL(MAX(ZCUSTOMSORTKEY), 0) AS c FROM ZGENERICALBUM WHERE ZKIND = 2
                """).first?.int("c") ?? 0) + 1
            sets.append("ZCUSTOMSORTKEY=\(next)")
        }
        // 在父文件夹里的排序键：源相簿用的是「最大值 + 1024」，同一条规矩
        if cols.contains("Z_FOK_PARENTFOLDER") {
            let next = (db.rows("SELECT IFNULL(MAX(Z_FOK_PARENTFOLDER), 0) AS c FROM ZGENERICALBUM")
                .first?.int("c") ?? 0) + 1024
            sets.append("Z_FOK_PARENTFOLDER=\(next)")
        }
        // 来源：写成「照片 App 自己建的」，别挂着别的 App 的牌子
        if cols.contains("ZIMPORTEDBYBUNDLEIDENTIFIER") {
            sets.append("ZIMPORTEDBYBUNDLEIDENTIFIER='com.apple.mobileslideshow.photospicker'")
        }
        for col in ["ZIMPORTSESSIONID", "ZCLOUDGUID"] where cols.contains(col) {
            sets.append("\(col)=NULL")
        }

        guard db.run("UPDATE cmi_album SET \(sets.joined(separator: ", "));") else {
            throw EditError.sql("改新相簿行")
        }
        guard db.run("INSERT INTO ZGENERICALBUM SELECT * FROM cmi_album;") else {
            throw EditError.sql("插入新相簿")
        }
        _ = db.run("DROP TABLE cmi_album;")

        guard db.run("UPDATE Z_PRIMARYKEY SET Z_MAX=\(newPK) WHERE Z_ENT=\(entity.ent);") else {
            throw EditError.sql("抬 Z_PRIMARYKEY（\(entity.name)）")
        }
        _ = tempID
        return newPK
    }

    /// 找「相簿」这个 CoreData 实体在 `Z_PRIMARYKEY` 里的那一行。
    ///
    /// 名字不可靠（`Z_NAME` 可能是 `GenericAlbum`，也可能整列都不存在），所以三级退：
    /// 1. 实体名等于 `ZGENERICALBUM` / `GenericAlbum`（大小写不敏感）；
    /// 2. 实体名里带 `ALBUM`、且 `Z_MAX` 装得下这张表的最大 PK（多个候选取最小的那个）；
    /// 3. 没有 `Z_NAME` 列时：`Z_MAX` 正好等于这张表最大 PK 的那一行（唯一才算）。
    private static func entityRow(_ db: SQLiteDB, tableMaxPK: Int) -> (ent: Int, name: String, max: Int)? {
        let cols = db.columns(of: "Z_PRIMARYKEY")
        guard cols.contains("Z_ENT") && cols.contains("Z_MAX") else { return nil }
        let selectName = cols.contains("Z_NAME") ? "Z_NAME" : "NULL AS Z_NAME"
        let rows = db.rows("SELECT Z_ENT, \(selectName), Z_MAX FROM Z_PRIMARYKEY ORDER BY Z_ENT")
        let all = rows.map {
            (ent: $0.int("Z_ENT"), name: $0.string("Z_NAME") ?? "", max: $0.int("Z_MAX"))
        }
        guard !all.isEmpty else { return nil }

        let exact: Set<String> = ["ZGENERICALBUM", "GENERICALBUM", "ALBUM"]
        if let hit = all.first(where: { exact.contains($0.name.uppercased()) }) { return hit }
        if let hit = all.filter({ $0.name.uppercased().contains("ALBUM") && $0.max >= tableMaxPK })
            .min(by: { $0.max < $1.max }) {
            return hit
        }
        // 完全没有名字可用：靠「Z_MAX 等于这张表最大 PK」唯一命中
        let byMax = all.filter { $0.max == tableMaxPK }
        if byMax.count == 1 { return byMax[0] }
        return nil
    }

    // MARK: - 成员关系

    private static func setMembership(_ db: SQLiteDB,
                                      join: JoinTable,
                                      assetPK: Int,
                                      album: Int,
                                      present: Bool) throws {
        let whereClause = "\(identifier(join.albumColumn))=\(album) AND \(identifier(join.assetColumn))=\(assetPK)"
        // 先删后插 = 幂等，也不依赖库里有没有唯一索引
        _ = db.run("DELETE FROM \(identifier(join.name)) WHERE \(whereClause);")
        guard present else { return }

        // 除了两列 ID，这张表可能还有排序列（本机 `Z_FOK_3ASSETS`）。列集不写死：
        // 多出来的列一律给「现有最大值 + 1」，至少保证 NOT NULL 能过。
        let cols = db.columns(of: join.name)
        let extras = cols.filter { $0 != join.albumColumn && $0 != join.assetColumn }
        var names = [join.albumColumn, join.assetColumn]
        var values = ["\(album)", "\(assetPK)"]
        for extra in extras {
            names.append(extra)
            if extra.hasPrefix("Z_FOK_") {
                // 排序键：真机实测是**同一本相簿内 1024 递增**（微信 5120/6144/7168），
                // 不是全局序号。按全局最大值 +1 写过一次，值不对齐，别再来。
                values.append("""
                    (SELECT IFNULL(MAX(\(identifier(extra))), 0) + 1024
                     FROM \(identifier(join.name)) WHERE \(identifier(join.albumColumn)) = \(album))
                    """)
            } else {
                values.append("(SELECT IFNULL(MAX(\(identifier(extra))), 0) + 1 FROM \(identifier(join.name)))")
            }
        }
        let sql = """
            INSERT INTO \(identifier(join.name)) (\(names.map(identifier).joined(separator: ", ")))
            VALUES (\(values.joined(separator: ", ")));
            """
        guard db.run(sql) else {
            throw EditError.sql("插入相簿成员 \(album) / 资产 \(assetPK)")
        }
    }

    private static func refreshCounts(_ db: SQLiteDB, join: JoinTable, album: Int) {
        let cols = db.columns(of: "ZGENERICALBUM")
        guard cols.contains("ZCACHEDCOUNT") else { return }
        let total = scalar(db, """
            SELECT COUNT(*) AS c FROM \(identifier(join.name))
            WHERE \(identifier(join.albumColumn)) = \(album)
            """)
        var sets = ["ZCACHEDCOUNT=\(total)"]

        let kindCount: (Int) -> Int = { kind in
            scalar(db, """
                SELECT COUNT(*) AS c FROM \(identifier(join.name)) j
                JOIN ZASSET a ON a.Z_PK = j.\(identifier(join.assetColumn))
                WHERE j.\(identifier(join.albumColumn)) = \(album) AND a.ZKIND = \(kind)
                """)
        }
        if cols.contains("ZCACHEDPHOTOSCOUNT") { sets.append("ZCACHEDPHOTOSCOUNT=\(kindCount(0))") }
        if cols.contains("ZCACHEDVIDEOSCOUNT") { sets.append("ZCACHEDVIDEOSCOUNT=\(kindCount(1))") }

        // 相簿的日期范围跟着内容走（正常相簿都有这两个值，空相簿是创建时间）。
        if cols.contains("ZSTARTDATE") && cols.contains("ZENDDATE") && total > 0,
           let range = db.rows("""
               SELECT MIN(a.ZDATECREATED) AS lo, MAX(a.ZDATECREATED) AS hi
               FROM \(identifier(join.name)) j JOIN ZASSET a ON a.Z_PK = j.\(identifier(join.assetColumn))
               WHERE j.\(identifier(join.albumColumn)) = \(album)
               """).first {
            let lo = range.double("lo")
            let hi = range.double("hi")
            if lo > 0, hi > 0 {
                sets.append("ZSTARTDATE=\(lo)")
                sets.append("ZENDDATE=\(hi)")
            }
        }

        _ = db.run("UPDATE ZGENERICALBUM SET \(sets.joined(separator: ", ")) WHERE Z_PK=\(album);")
    }

    // MARK: - 小工具

    private static func assetExists(_ db: SQLiteDB, pk: Int) -> Bool {
        scalar(db, "SELECT COUNT(*) AS c FROM ZASSET WHERE Z_PK = \(pk)") > 0
    }

    private static func scalar(_ db: SQLiteDB, _ sql: String) -> Int {
        db.rows(sql).first?.int("c") ?? 0
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func identifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 纯 hex 的随机串（`UUID` 自带连字符，去掉就是 32 位 hex / 16 字节）。
    private static func randomHex(_ bytes: Int) -> String {
        var text = ""
        while text.count < bytes * 2 {
            text += UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return String(text.prefix(bytes * 2)).lowercased()
    }
}
