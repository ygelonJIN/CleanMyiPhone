import Foundation

/// 把一批转换结果写进 `Photos.sqlite` 的副本。
///
/// 只 UPDATE/INSERT 现有表，不重建库；每个新资产都复制原资产那一行，
/// 所以相簿关联（`Z_33ASSETS`）、收藏、截图 subtype、日期、GPS 都会跟着走。
/// 写之前把 CoreData 的触发器临时摘掉（它们要调 `NSCoreData...` 函数，
/// 纯 sqlite3 没有），插完再原样装回去。
enum ConversionDB {

    static func apply(dbPath: String, workDir: URL, records: [ConversionRecord]) throws -> URL {
        let fm = FileManager.default
        let dbDir = workDir.appendingPathComponent("db", isDirectory: true)
        try? fm.removeItem(at: dbDir)
        try fm.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let workDB = dbDir.appendingPathComponent("Photos.sqlite")

        for suffix in ["", "-wal", "-shm"] {
            let source = dbPath + suffix
            guard fm.fileExists(atPath: source) else { continue }
            try fm.copyItem(atPath: source, toPath: workDB.path + suffix)
        }

        guard let db = SQLiteDB(path: workDB.path, writable: true) else {
            throw ConversionDBError.cannotPrepare("打不开 \(workDB.path)")
        }
        guard db.run("PRAGMA wal_checkpoint(TRUNCATE);") else {
            throw ConversionDBError.sqlFailed("wal_checkpoint")
        }
        _ = db.run("PRAGMA journal_mode=DELETE;")

        let triggers = db.rows("""
            SELECT name, sql FROM sqlite_master
            WHERE type='trigger' AND tbl_name IN ('ZASSET','ZADDITIONALASSETATTRIBUTES','Z_33ASSETS')
            """)
        for trigger in triggers {
            guard let name = trigger.string("name") else { continue }
            _ = db.run("DROP TRIGGER IF EXISTS \"\(name)\";")
        }

        for record in records {
            let old = record.originalPK
            let new = record.newPK
            let name = quote(record.newFileName)
            let uuid = quote(record.newUUID)
            let uti = quote(record.newUTI)
            let directory = quote(record.directory)
            let subtype = record.isScreenshot ? 10 : 0
            let screenshot = record.isScreenshot ? 1 : 0
            let favorite = record.favorite ? 1 : 0

            // 批次期间原图可能被删了；新库里找不到就跳过，别插一条指向不存在资产的行。
            let exists = db.rows("SELECT COUNT(*) AS c FROM ZASSET WHERE Z_PK=\(old)")
                .first?.int("c") ?? 0
            guard exists > 0 else { continue }

            _ = db.run("DROP TABLE IF EXISTS cmi_a;")
            guard db.run("CREATE TEMP TABLE cmi_a AS SELECT * FROM ZASSET WHERE Z_PK=\(old);") else {
                throw ConversionDBError.sqlFailed("copy ZASSET \(old)")
            }
            guard db.run("""
                UPDATE cmi_a SET
                  Z_PK=\(new), ZUUID=\(uuid), ZDIRECTORY=\(directory), ZFILENAME=\(name),
                  ZUNIFORMTYPEIDENTIFIER=\(uti), ZWIDTH=\(record.newWidth), ZHEIGHT=\(record.newHeight),
                  ZORIENTATION=1, ZKINDSUBTYPE=\(subtype), ZPLAYBACKSTYLE=1,
                  ZISDETECTEDSCREENSHOT=\(screenshot), ZFAVORITE=\(favorite),
                  ZADDITIONALATTRIBUTES=\(new),
                  ZVIDEOCPDURATIONVALUE=0, ZVIDEOCPVISIBILITYSTATE=0,
                  ZVIDEODEFERREDPROCESSINGNEEDED=0,
                  ZVIDEOKEYFRAMETIMESCALE=0, ZVIDEOKEYFRAMEVALUE=0,
                  ZEXTENDEDATTRIBUTES=0, ZCOMPUTEDATTRIBUTES=0,
                  ZCOMPUTESYNCATTRIBUTES=0, ZMEDIAANALYSISATTRIBUTES=0,
                  ZPHOTOANALYSISATTRIBUTES=0
                WHERE Z_PK=\(old);
                """) else {
                throw ConversionDBError.sqlFailed("update ZASSET \(old)")
            }
            guard db.run("INSERT INTO ZASSET SELECT * FROM cmi_a;") else {
                throw ConversionDBError.sqlFailed("insert ZASSET \(new)")
            }
            _ = db.run("DROP TABLE cmi_a;")

            _ = db.run("DROP TABLE IF EXISTS cmi_b;")
            guard db.run("CREATE TEMP TABLE cmi_b AS SELECT * FROM ZADDITIONALASSETATTRIBUTES WHERE Z_PK=\(old);") else {
                throw ConversionDBError.sqlFailed("copy AZAA \(old)")
            }
            guard db.run("""
                UPDATE cmi_b SET
                  Z_PK=\(new), ZASSET=\(new), ZORIGINALFILESIZE=\(record.newSize),
                  ZORIGINALWIDTH=\(record.newWidth), ZORIGINALHEIGHT=\(record.newHeight),
                  ZORIGINALFILENAME=\(quote(record.originalFileName)),
                  ZORIGINALASSETSUUID=\(quote(record.originalUUID)),
                  ZORIGINALORIENTATION=1,
                  ZIMPORTEDBYBUNDLEIDENTIFIER='local.cleanmyiphone.q\(record.quality)',
                  ZIMPORTEDBYDISPLAYNAME='cleanmyiphone',
                  ZVIDEOCPDISPLAYTIMESCALE=0, ZVIDEOCPDISPLAYVALUE=0,
                  ZVIDEOCPDURATIONTIMESCALE=0,
                  ZASSETDESCRIPTION=0, ZEDITEDIPTCATTRIBUTES=0, ZMEDIAMETADATA=0,
                  ZSCENEPRINT=0, ZUNMANAGEDADJUSTMENT=0
                WHERE Z_PK=\(old);
                """) else {
                throw ConversionDBError.sqlFailed("update AZAA \(old)")
            }
            guard db.run("INSERT INTO ZADDITIONALASSETATTRIBUTES SELECT * FROM cmi_b;") else {
                throw ConversionDBError.sqlFailed("insert AZAA \(new)")
            }
            _ = db.run("DROP TABLE cmi_b;")

            guard db.run("""
                INSERT INTO Z_33ASSETS (Z_33ALBUMS, Z_3ASSETS, Z_FOK_3ASSETS)
                SELECT Z_33ALBUMS, \(new), Z_FOK_3ASSETS
                FROM Z_33ASSETS WHERE Z_3ASSETS=\(old);
                """) else {
                throw ConversionDBError.sqlFailed("copy album joins \(old)")
            }
        }

        let maxPK = records.map(\.newPK).max() ?? 0
        guard db.run("UPDATE Z_PRIMARYKEY SET Z_MAX=\(maxPK) WHERE Z_ENT=3;") else {
            throw ConversionDBError.sqlFailed("Z_PRIMARYKEY Asset")
        }
        guard db.run("UPDATE Z_PRIMARYKEY SET Z_MAX=\(maxPK) WHERE Z_ENT=1;") else {
            throw ConversionDBError.sqlFailed("Z_PRIMARYKEY AZAA")
        }

        for trigger in triggers {
            guard let sql = trigger.string("sql") else { continue }
            _ = db.run(sql)
        }

        guard db.quickCheck() else { throw ConversionDBError.integrityFailed }
        return workDB
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
