import Foundation
import SQLite3

/// 极简只读 SQLite 封装：只做 SELECT，不建表不写入。
final class SQLiteDB {

    private var handle: OpaquePointer?

    struct Row {
        private let values: [String: Any]
        init(_ values: [String: Any]) { self.values = values }

        // **SQLite 是动态类型的**：同一列在不同行可能是 integer 也可能是 real。
        // `ZDATECREATED` 实测就是这样（本机 2328 行 integer / 2958 行 real）——
        // 以前 `double()` 只认 `as? Double`，于是那 2328 条资产的拍摄时间全变成 0
        // （= 2001-01-01），排序、按时间筛选、"新照片是否让快照过期"全跟着错。
        func int(_ key: String) -> Int { Int(int64(key)) }

        func int64(_ key: String) -> Int64 {
            if let value = values[key] as? Int64 { return value }
            if let value = values[key] as? Double { return Int64(value) }
            if let value = values[key] as? NSNumber { return value.int64Value }
            return 0
        }

        func double(_ key: String) -> Double {
            if let value = values[key] as? Double { return value }
            if let value = values[key] as? Int64 { return Double(value) }
            if let value = values[key] as? NSNumber { return value.doubleValue }
            return 0
        }

        func string(_ key: String) -> String? { values[key] as? String }
    }

    /// writable: WAL 模式下的库必须以读写方式打开，SQLite 才能用/建 -shm
    init?(path: String, writable: Bool = true, immutable: Bool = false) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let uri: String
        if immutable {
            uri = "file:\(encoded)?mode=ro&immutable=1"
        } else if writable {
            uri = "file:\(encoded)?mode=rw"
        } else {
            uri = "file:\(encoded)?mode=ro"
        }
        var pointer: OpaquePointer?
        let base = writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY
        let flags = base | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &pointer, flags, nil) == SQLITE_OK else {
            sqlite3_close(pointer)
            return nil
        }
        handle = pointer
    }

    deinit { sqlite3_close(handle) }

    func rows(_ sql: String) -> [Row] {
        guard let handle else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var values: [String: Any] = [:]
            let count = sqlite3_column_count(statement)
            for index in 0..<count {
                guard let cName = sqlite3_column_name(statement, index) else { continue }
                let name = String(cString: cName)
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    values[name] = Int64(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    values[name] = sqlite3_column_double(statement, index)
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, index) {
                        values[name] = String(cString: text)
                    }
                default:
                    break
                }
            }
            result.append(Row(values))
        }
        return result
    }

    /// 完整性检查：能返回 ok 才算一个可用的库
    func quickCheck() -> Bool {
        let rows = rows("PRAGMA quick_check")
        guard let first = rows.first else { return false }
        return first.string("quick_check") == "ok"
    }

    func columns(of table: String) -> [String] {
        rows("PRAGMA table_info('\(table)')").compactMap { $0.string("name") }
    }

    func tables(matching pattern: String) -> [String] {
        rows("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '\(pattern)'")
            .compactMap { $0.string("name") }
    }
}
