import Darwin
import Foundation

private var crashFD: Int32 = -1

private func crashLog(_ text: String) {
    guard crashFD >= 0 else { return }
    text.withCString { _ = Darwin.write(crashFD, $0, strlen($0)) }
}

/// 调试用：崩溃时把调用栈写进 /tmp/cmi-crash.txt（只在 CMI_TRACE_CRASH=1 时启用）
enum CrashTracer {
    static func install() {
        guard ProcessInfo.processInfo.environment["CMI_TRACE_CRASH"] != nil else { return }
        crashFD = open("/tmp/cmi-crash.txt", O_WRONLY | O_CREAT | O_TRUNC, 0o644)

        NSSetUncaughtExceptionHandler { exception in
            crashLog("NSException: \(exception.name.rawValue)\n\(exception.reason ?? "-")\n")
            crashLog(exception.callStackSymbols.joined(separator: "\n") + "\n")
        }

        for sig in [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP] {
            signal(sig) { signalNumber in
                crashLog("\n--- signal \(signalNumber) ---\n")
                var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 96)
                let count = backtrace(&frames, Int32(frames.count))
                if crashFD >= 0 {
                    backtrace_symbols_fd(&frames, count, crashFD)
                }
                crashLog("--- end ---\n")
                _ = Darwin.signal(signalNumber, SIG_DFL)
                raise(signalNumber)
            }
        }
    }
}
