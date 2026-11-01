import AppKit
import Darwin
import Foundation

/// 「不管怎么退出，本机都不留痕」的四层保险。
///
/// | 退出方式 | 谁负责清 |
/// |---|---|
/// | ⌘Q / 菜单退出 / 点窗口红点 | `applicationWillTerminate` → `AppStore.purgeOnTerminate()`（完整清） |
/// | `kill <pid>` / Ctrl+C / 关机信号（SIGTERM/SIGINT/SIGHUP/SIGQUIT） | 本文件第 1 段（完整清） |
/// | 崩溃 / 断言（SIGSEGV/SIGBUS/SIGABRT/SIGILL） | 本文件第 2 段：只 `unlink` 固定那几个文件（异步信号安全），剩下的由下次启动兜住 |
/// | `kill -9` / 断电 | 进程没有任何执行机会 —— 只能靠**下次启动第一步**的清理（`bootstrap` 里的 `purgeLocalDataOnDisk`） |
///
/// 关键点：前两条是"当场清干净"，后两条保证"最迟下次启动开头就清干净"。
/// 所以 `bootstrap()` 里那一次启动清理**不能删掉**：它是 SIGKILL / 崩溃的唯一兜底。
enum PurgeGuard {
    /// 信号源必须被保住，出了作用域就被回收，handler 也就没了
    private static var signalSources: [DispatchSourceSignal] = []

    /// 预先拼好的绝对路径（C 字符串），handler 里只做 unlink，不碰 Foundation
    private static var sensitivePaths: [UnsafeMutablePointer<CChar>] = []

    /// 数据根目录：`~/Library/Application Support/cleanmyiphone`
    static var dataDirectory: String {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cleanmyiphone", isDirectory: true).path
    }

    static func install() {
        let base = dataDirectory
        var paths: [UnsafeMutablePointer<CChar>] = []
        for name in ["Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm",
                     "thumbnailConfiguration", "thumb-log.txt", "instance.lock"] {
            if let c = strdup(base + "/" + name) { paths.append(c) }
        }
        sensitivePaths = paths

        // 1) 可捕获的退出信号：完整清理（跑在队列上，能安全用 Foundation）
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler {
                AppStore.purgeOnTerminate()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        // 2) 致命信号：handler 里只能做异步信号安全的事（unlink），其余交给下次启动
        for sig in [SIGSEGV, SIGBUS, SIGABRT, SIGILL] {
            signal(sig) { signalNumber in
                PurgeGuard.unlinkSensitiveFiles()
                signal(signalNumber, SIG_DFL)
                raise(signalNumber)
            }
        }
    }

    /// 只 `unlink` 几个固定文件：可以在信号 handler 里调用（async-signal-safe）
    static func unlinkSensitiveFiles() {
        for path in sensitivePaths { _ = unlink(path) }
    }
}
