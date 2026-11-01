import Foundation

/// 落盘痕迹的**唯一**清单。
///
/// 以前是三个地方各删各的：`AppStore.purgeLocalDataOnDisk`、`PurgeGuard.sensitivePaths`、
/// `DeviceFiles.purgeTransientFiles`，三份内容互不相同，于是新加一处落盘（比如
/// `trash.json`、`battery-dump.txt`、系统写的 savedState）就必然漏一处。
/// 现在所有路径只在**这里**定义，三个清理时机都读这一份：
///
/// | 时机 | 入口 | 能做什么 |
/// |---|---|---|
/// | 正常退出 / ⌘Q / 红点（进程会退出） | `purgeAll()` | 全清 |
/// | SIGTERM / SIGINT / SIGHUP / SIGQUIT | `purgeAll()`（跑在队列上） | 全清 |
/// | SIGSEGV / SIGBUS / SIGABRT / SIGILL | `unlinkRegistered()` | 只 unlink，异步信号安全 |
/// | `kill -9` / 断电 | 下次启动第一步的 `purgeAll()` | 全清 |
///
/// 崩溃那种时机拿不到目录列表（`readdir` 不是异步信号安全的），所以**每写一个
/// 文件就登记一次**（`registerTrace`），崩溃时按登记过的路径逐个 unlink。
enum TraceRegistry {

    // MARK: - 路径（全项目只在这里定义）

    /// 数据根目录 `~/Library/Application Support/cleanmyiphone`。
    /// `CMI_TRACE_DIR` 只是测试用：把整棵数据目录挪到临时位置，测崩溃清场时不动真数据。
    static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CMI_TRACE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cleanmyiphone", isDirectory: true)
    }

    /// 数据根目录下**名字固定**的文件（崩溃信号里也能按固定路径删掉）
    static let fileNames: [String] = [
        "Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm",
        "thumbnailConfiguration", "thumb-log.txt", "trash.json",
        // 这两个只有机型和键名（没有照片），但按「零痕迹」的标准一并删；
        // 要排查时用 CMI_DEBUG 重新生成即可。
        "battery-dump.txt", "device-dump.txt",
        "instance.lock"
    ]

    /// 数据根目录下要**整个目录**清掉的
    static let directoryNames: [String] = ["thumbs"]

    /// `/tmp` 下的调试日志（只有开了 CMI_DEBUG / CMI_TRACE_CRASH 才有，
    /// 但里面有照片文件名和历史运行记录，属于痕迹，一并删）
    static let absoluteFileNames: [String] = [
        "/tmp/cmi-app.log", "/tmp/cmi-library.log",
        "/tmp/cmi-helper-err.log", "/tmp/cmi-crash.txt",
        // 探针模式（--probe*）的输出，里面有照片文件名和路径
        "/tmp/cmi-probe.log", "/tmp/cmi-shot.png"
    ]

    /// `$TMPDIR` 下的一次性落盘：原图 / 预览图 / 原视频
    static var temporaryDirectories: [URL] {
        let tmp = FileManager.default.temporaryDirectory
        return ["cleanmyiphone-raw", "cleanmyiphone-preview"]
            .map { tmp.appendingPathComponent($0, isDirectory: true) }
    }

    /// 系统替我们写的界面状态（窗口位置、屏幕 UUID）。
    /// 系统会自己重建，删掉不影响使用；里面没有照片内容，但按「零痕迹」一并清。
    static var systemStateDirectories: [URL] {
        [FileManager.default.temporaryDirectory
            .appendingPathComponent("local.cleanmyiphone.savedState", isDirectory: true)]
    }

    /// 系统写的崩溃 / 卡死报告目录
    static var diagnosticReportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// 崩溃报告的文件名前缀（`cleanmyiphone-2026-11-01-171359.ips`）
    static var diagnosticReportPrefix: String {
        (Bundle.main.executableURL?.lastPathComponent ?? "cleanmyiphone") + "-"
    }

    // MARK: - 已写文件的登记（崩溃那一刻靠它）

    /// 登记容量。一次运行通常只写几百个缩略图；5000 张全刷一遍也够。
    /// 超出就停止登记（`overflowed` 置真，下次启动的 `purgeAll()` 会整目录清）。
    private static let capacity = 8192
    private static var slots = [UnsafeMutablePointer<CChar>?](repeating: nil, count: capacity)
    private static var used = 0
    private static var overflowed = false

    /// 每写一个会留痕的文件就调一次。重复登记是安全的（unlink 不存在的文件只返回 -1）。
    static func registerTrace(_ url: URL) {
        guard used < capacity else {
            overflowed = true
            return
        }
        guard let c = strdup(url.path) else { return }
        slots[used] = c
        used += 1
    }

    /// 文件自己已经删掉了（正常路径）：登记不撤也没关系，
    /// unlink 一个不存在的路径是空操作，这里不维护删除，省掉一把锁。
    static func clearRegistered() {
        for index in 0..<used { free(slots[index]) }
        for index in 0..<used { slots[index] = nil }
        used = 0
        overflowed = false
    }

    /// 固定名字那批的 C 字符串，**必须在装信号 handler 之前**准备好：
    /// 信号上下文里不能调 Foundation（`FileManager` / `Bundle` 都会分配内存、拿锁）。
    private static var fixedPaths = [UnsafeMutablePointer<CChar>?]()

    /// 装机时调一次：把「固定名字」的绝对路径预先拼好。
    static func prepareSignalSafePaths() {
        guard fixedPaths.isEmpty else { return }
        let base = dataDirectory.path
        var paths: [UnsafeMutablePointer<CChar>?] = []
        for name in fileNames {
            paths.append(strdup(base + "/" + name))
        }
        for path in absoluteFileNames {
            paths.append(strdup(path))
        }
        fixedPaths = paths
    }

    /// **只能在信号 handler 里调**：逐个 unlink 登记过的路径，不碰 Foundation。
    /// 目录里的东西（`thumbs/`）靠 `registerTrace` 登记的名字删，所以也能删干净。
    static func unlinkRegistered() {
        for slot in fixedPaths {
            guard let path = slot else { continue }
            _ = remove(path)
        }
        let count = used
        guard count > 0 else { return }
        for index in 0..<count {
            guard let path = slots[index] else { continue }
            _ = remove(path)
        }
    }

    // MARK: - 全清（退出 / 启动）

    /// 全清并回查。返回**没删掉的**条目，界面要如实显示，不能假装已清空。
    @discardableResult
    static func purgeAll() -> [String] {
        let fm = FileManager.default
        prepareSignalSafePaths()
        unlinkRegistered()

        // 老版本的「自动清空」开关 key（现在不留痕是无条件的，这个 key 只是痕迹）
        UserDefaults.standard.removeObject(forKey: "cmi.autoPurge")

        let base = dataDirectory
        for name in fileNames {
            try? fm.removeItem(at: base.appendingPathComponent(name))
        }
        for name in directoryNames {
            try? fm.removeItem(at: base.appendingPathComponent(name))
        }
        for path in absoluteFileNames {
            try? fm.removeItem(atPath: path)
        }
        for dir in temporaryDirectories {
            try? fm.removeItem(at: dir)
        }
        for dir in systemStateDirectories {
            try? fm.removeItem(at: dir)
        }
        removeDiagnosticReports()

        var leftovers: [String] = []
        for name in fileNames where fm.fileExists(atPath: base.appendingPathComponent(name).path) {
            leftovers.append(name)
        }
        for name in directoryNames where fm.fileExists(atPath: base.appendingPathComponent(name).path) {
            leftovers.append(name + "/")
        }
        for dir in temporaryDirectories where fm.fileExists(atPath: dir.path) {
            leftovers.append(dir.lastPathComponent)
        }
        for path in absoluteFileNames where fm.fileExists(atPath: path) {
            leftovers.append((path as NSString).lastPathComponent)
        }

        clearRegistered()
        return leftovers
    }

    /// 删掉系统替我们写的崩溃 / 卡死报告（属主是自己，删得掉）。
    /// 崩溃那一次的 `.ips` 要等**下次启动**才删得掉 —— 这是唯一无法当场闭合的窗口，
    /// 内容只有堆栈和进程名，没有照片数据。
    private static func removeDiagnosticReports() {
        let fm = FileManager.default
        let prefix = diagnosticReportPrefix
        guard let names = try? fm.contentsOfDirectory(atPath: diagnosticReportDirectory.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            try? fm.removeItem(at: diagnosticReportDirectory.appendingPathComponent(name))
        }
    }
}
