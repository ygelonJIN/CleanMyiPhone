import AppKit
import Darwin
import Foundation

/// 「不管怎么退出，本机都不留痕」的四层保险。
///
/// | 退出方式 | 谁负责清 |
/// |---|---|
/// | ⌘Q / 菜单退出 / 点窗口红点 | `applicationWillTerminate` → `AppStore.purgeOnTerminate()`（全清） |
/// | `kill <pid>` / Ctrl+C / 注销关机（SIGTERM/SIGINT/SIGHUP/SIGQUIT） | 本文件第 1 段（全清） |
/// | 崩溃 / 断言（SIGSEGV/SIGBUS/SIGABRT/SIGILL） | 本文件第 2 段：只 `unlink`（异步信号安全），删的是 `TraceRegistry` 里登记过的路径 |
/// | `kill -9` / 断电 | 进程没有任何执行机会 —— 只能靠**下次启动第一步**的清理（`bootstrap` 里的 `purgeLocalDataOnDisk`） |
///
/// 关键点：前两条是"当场清干净"，后两条保证"最迟下次启动开头就清干净"。
/// 所以 `bootstrap()` 里那一次启动清理**不能删掉**：它是 SIGKILL / 崩溃的唯一兜底。
///
/// **要删什么东西不在这里列** —— 全部在 `TraceRegistry` 里定义一份，
/// 本文件只负责"什么时机触发"。
enum PurgeGuard {
    /// 信号源必须被保住，出了作用域就被回收，handler 也就没了
    private static var signalSources: [DispatchSourceSignal] = []

    static var dataDirectory: String { TraceRegistry.dataDirectory.path }

    static func install() {
        // 固定名字那批路径必须在这时候预先拼好：信号 handler 里不能调 Foundation
        TraceRegistry.prepareSignalSafePaths()

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

    /// 只 `unlink`：可以在信号 handler 里调用（async-signal-safe）
    static func unlinkSensitiveFiles() {
        TraceRegistry.unlinkRegistered()
    }
}
