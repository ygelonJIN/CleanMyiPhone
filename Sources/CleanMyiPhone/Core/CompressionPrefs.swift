import Foundation

/// **压缩参数的记忆**（2026-11 用户要求：每次设的参数要留住，下次打开还是那几个数）。
///
/// 这是整个 App **唯一主动保留到下次启动的东西**，所以位置和清场规则必须写清楚：
///
/// - 存在数据目录 `<数据目录>/compression-prefs.json`，**故意不进 `TraceRegistry.fileNames`**
///   —— 进了就会被 `purgeAll()`（退出 / 崩溃 / 下次启动）删掉，那就不叫记住了。
/// - 所以 `schedulePostExitSweep` 那个「目录只剩 instance.lock 才整棵删」的判断也不会命中，
///   数据目录会留着，里面只有这份 JSON（+ 单实例锁）。除此之外仍然零痕迹：
///   相册库四件套、缩略图、日志、探针输出、偏好 plist 全照删。
/// - 内容只有三个数（比例 / 格式 / 质量 / 去实况），**不含任何照片信息**，
///   也不记录「压过哪些照片」—— 那不是参数，是痕迹。
struct CompressionPrefs: Codable, Equatable {

    var ratio: Double
    var format: ConversionProfile.Format
    var quality: Double
    var stripLive: Bool

    static let defaultValue = CompressionPrefs(
        ratio: 0.6, format: .heic, quality: 0.8, stripLive: true)

    init(ratio: Double, format: ConversionProfile.Format, quality: Double, stripLive: Bool) {
        self.ratio = ratio
        self.format = format
        self.quality = quality
        self.stripLive = stripLive
    }

    init(profile: ConversionProfile) {
        self.init(ratio: profile.ratio,
                  format: profile.format,
                  quality: profile.quality,
                  stripLive: profile.stripLive)
    }

    /// 存盘那一份参数 → 压缩任务的参数。
    var profile: ConversionProfile {
        ConversionProfile(ratio: ratio, format: format, quality: quality, stripLive: stripLive)
    }

    // MARK: - 存取

    static var fileURL: URL {
        TraceRegistry.dataDirectory.appendingPathComponent("compression-prefs.json")
    }

    /// 上次用过的参数。文件不在 / 读坏了 / 被手动删了，一律回默认值，不报错、不打扰用户。
    /// 解析后顺手夹一遍范围：手改过的 JSON 里可能有 `ratio: 7`，那会让预估直接崩。
    static func load() -> CompressionPrefs {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(CompressionPrefs.self, from: data)
        else { return defaultValue }
        return sanitized(saved)
    }

    /// **不登记 `registerTrace`**：登记了崩溃/退出那一刻就会被 unlink，
    /// 记忆正好在自己手里丢掉。这里是要留下来，和别的落盘文件不是一类。
    func save() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: TraceRegistry.dataDirectory,
                                   withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(CompressionPrefs.sanitized(self))
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            // 记不住参数不影响压缩本身，只是下次回到默认值 —— 不弹窗、不打断。
            // 这里也不写日志：`AppStore` 是 `@MainActor`，为了记一条 debug 日志去跨 actor
            // 不值得，而且写日志本身又是一次落盘。
        }
    }

    private static func sanitized(_ prefs: CompressionPrefs) -> CompressionPrefs {
        CompressionPrefs(
            ratio: min(1.0, max(0.05, prefs.ratio)),
            format: prefs.format,
            quality: min(1.0, max(0.1, prefs.quality)),
            stripLive: prefs.stripLive
        )
    }
}
