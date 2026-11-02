import Foundation

enum PhotoDaemonError: LocalizedError {
    case devicectlMissing
    case commandFailed(String)
    case daemonNotBack

    var errorDescription: String? {
        switch self {
        case .devicectlMissing:
            return "找不到 xcrun/devicectl（需要装 Xcode）。没有它就只能重启手机才能让相册重新读库"
        case .commandFailed(let detail):
            return "devicectl 执行失败：\(detail)"
        case .daemonNotBack:
            return "assetsd 没有重新起来，可能需要重启 iPhone"
        }
    }
}

/// 不重启手机，让相册重新读 `Photos.sqlite`。
///
/// 真正管库的是 `assetsd`（不是 `photolibraryd`）。流程：
/// terminate `assetsd` → terminate Photos.app → launch Photos.app，
/// Photos 会把 `assetsd` 重新拉起来，新库就生效了。
enum PhotoDaemon {

    static func restartLibrary(udid: String) throws {
        let xcrun = "/usr/bin/xcrun"
        guard FileManager.default.isExecutableFile(atPath: xcrun) else {
            throw PhotoDaemonError.devicectlMissing
        }

        let before = try run([xcrun, "devicectl", "device", "info", "processes", "--device", udid])
        let assets = pids(in: before, marker: "AssetsLibrary.framework/Support/assetsd")
        let photos = pids(in: before, marker: "Photos.app/Photos")

        for pid in assets {
            _ = try? run([xcrun, "devicectl", "device", "process", "terminate",
                          "--device", udid, "--pid", "\(pid)"])
        }
        for pid in photos {
            _ = try? run([xcrun, "devicectl", "device", "process", "terminate",
                          "--device", udid, "--pid", "\(pid)"])
        }

        _ = try? run([xcrun, "devicectl", "device", "process", "launch",
                      "--device", udid, "com.apple.mobileslideshow"])

        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 1)
            guard let output = try? run([xcrun, "devicectl", "device", "info", "processes",
                                         "--device", udid]) else { continue }
            if !pids(in: output, marker: "AssetsLibrary.framework/Support/assetsd").isEmpty {
                return
            }
        }
        throw PhotoDaemonError.daemonNotBack
    }

    private static func pids(in output: String, marker: String) -> [Int] {
        output.split(separator: "\n").compactMap { line in
            guard line.contains(marker) else { return nil }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = parts.first, let pid = Int(first) else { return nil }
            return pid
        }
    }

    private static func run(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw PhotoDaemonError.commandFailed(error.localizedDescription)
        }
        // 必须先读管道再 waitUntilExit：`device info processes` 有 500 行，
        // 超过管道缓冲区时子进程会卡在写、父进程卡在 wait，直接死锁。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
