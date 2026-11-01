import AppKit
import Foundation

/// 单实例锁。
///
/// 为什么必须有：这台机器上同时跑两个 cleanmyiphone，两个都会拉 ImageCaptureCore、
/// 各起一个 `--fetch-library` 子进程，互相抢手机的同一条 AFC 通道，
/// 表现就是「相册索引读不出来 / 读几分钟」。直接双击 `.app` 有 LaunchServices 拦着，
/// 但命令行 `./build/cleanmyiphone.app/Contents/MacOS/cleanmyiphone` 起两次不会有任何阻拦。
///
/// 实现用 `flock` 而不是「找到同名进程」：进程一退出内核自动释放，
/// 不会留下「上次被 kill -9 了，锁还在」的死锁文件。
enum SingleInstance {
    private static var lockFD: Int32 = -1

    private static var lockURL: URL {
        // 测试用：把锁挪到 /tmp 这种一定可写的地方
        if let override = ProcessInfo.processInfo.environment["CMI_LOCK_PATH"] {
            return URL(fileURLWithPath: override)
        }
        let base = TraceRegistry.dataDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("instance.lock")
    }

    /// 拿到锁返回 true；已有实例在跑返回 false（并尝试把它的窗口叫到前面）。
    static func acquire() -> Bool {
        let path = lockURL.path
        let fd = path.withCString { open($0, O_CREAT | O_RDWR, 0o600) }
        guard fd >= 0 else {
            dbg("锁文件打不开（errno \(errno)），本次不启用单实例保护")
            return true                        // 锁文件都建不出来就别拦着用户
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd                        // 进程活多久就占多久，退出由内核释放
            dbg("已持有单实例锁 \(path)")
            return true
        }
        close(fd)
        dbg("单实例锁已被占用 \(path)")
        return false
    }

    private static func dbg(_ line: String) {
        guard ProcessInfo.processInfo.environment["CMI_DEBUG"] != nil else { return }
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/cmi-app.log")) {
            handle.seekToEndOfFile()
            handle.write(Data(("[boot] " + line + "\n").utf8))
            try? handle.close()
        }
    }

    /// 已有实例时：把它叫到前台，本进程直接退。
    static func activateExisting() {
        let identifier = Bundle.main.bundleIdentifier ?? "local.cleanmyiphone"
        let mine = ProcessInfo.processInfo.processIdentifier
        let candidates = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != mine }
        if let running = candidates.first {
            running.activate()
            FileHandle.standardError.write(Data("已有实例在运行（pid \(running.processIdentifier)），已激活该窗口，本次启动退出\n".utf8))
        } else {
            FileHandle.standardError.write(Data("已有实例在运行，本次启动退出\n".utf8))
        }
    }
}
