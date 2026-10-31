import AppKit
import Foundation

/// 没有 iPhone 也能开发：生成一批稳定、可复现的假资产。
final class FixtureDevice: DeviceSource {

    let displayName = "iPhone（模拟）"
    let supportsDeletion = false

    private var assets: [Asset] = []
    private var thumbnailCache: [String: NSImage] = [:]

    init(count: Int = 900) {
        var rng = SeededGenerator(seed: 0xC1EA_0001)
        var result: [Asset] = []
        let now = Date()
        let folders = (0..<6).map { String(format: "DCIM/1%02dAPPLE", $0 + 1) }

        for index in 0..<count {
            let isVideo = rng.nextInt(upperBound: 100) < 18
            let kind: MediaKind = isVideo ? .video : .photo
            let roll = rng.nextInt(upperBound: 100)

            var tags: MediaTag = []
            if roll < 12 { tags.insert(.screenshot) }
            if roll >= 12 && roll < 16 { tags.insert(.panorama) }
            if roll >= 16 && roll < 26 { tags.insert(.portrait) }
            if roll >= 26 && roll < 34 { tags.insert(.selfie) }
            if roll >= 34 && roll < 42 { tags.insert(.live) }
            if roll >= 92 { tags.insert(.slomo) }
            if roll >= 88 && roll < 92 { tags.insert(.timelapse) }
            if rng.nextInt(upperBound: 100) < 8 { tags.insert(.burst) }
            if rng.nextInt(upperBound: 100) < 6 { tags.insert(.favorite) }
            if rng.nextInt(upperBound: 100) < 2 { tags.insert(.hidden) }

            let bytes: Int64 = isVideo
                ? Int64(rng.nextInt(upperBound: 900) + 20) * 1_000_000
                : Int64(rng.nextInt(upperBound: 9_000) + 900) * 1_000
            let cloudOnly = rng.nextInt(upperBound: 100) < 4
            let ageSeconds = Double(rng.nextInt(upperBound: 60 * 60 * 24 * 900))
            let createdAt = now.addingTimeInterval(-ageSeconds)
            let ext = isVideo ? (roll >= 92 ? "MOV" : "MOV") : "HEIC"
            let name = String(format: "IMG_%04d.%@", 1000 + index, ext)

            result.append(
                Asset(
                    id: "fixture-\(index)",
                    fileName: name,
                    folder: folders[index % folders.count],
                    byteSize: cloudOnly ? 0 : bytes,
                    createdAt: createdAt,
                    kind: kind,
                    tags: tags,
                    pixelWidth: isVideo ? 3840 : 4032,
                    pixelHeight: isVideo ? 2160 : 3024,
                    duration: isVideo ? Double(rng.nextInt(upperBound: 240) + 3) : 0
                )
            )
        }
        self.assets = result
    }

    func load() async throws -> [Asset] {
        assets
    }

    func thumbnail(for asset: Asset, maxPixel: Int) async -> NSImage? {
        if let cached = thumbnailCache[asset.id] { return cached }
        let image = Self.makeThumbnail(for: asset, maxPixel: maxPixel)
        thumbnailCache[asset.id] = image
        return image
    }

    func delete(ids: [Asset.ID]) async -> (succeeded: [Asset.ID], failed: [(id: Asset.ID, message: String)]) {
        let target = Set(ids)
        let removed = assets.filter { target.contains($0.id) }.map(\.id)
        assets.removeAll { target.contains($0.id) }
        for id in removed { thumbnailCache[id] = nil }
        return (removed, [])
    }

    // MARK: - 生成占位缩略图

    private static func makeThumbnail(for asset: Asset, maxPixel: Int) -> NSImage {
        let side = CGFloat(min(maxPixel, 256))
        let size = NSSize(width: side, height: side * 0.75)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let hue = CGFloat(abs(asset.id.hashValue % 360)) / 360
        let top = NSColor(hue: hue, saturation: 0.42, brightness: 0.72, alpha: 1)
        let bottom = NSColor(hue: hue, saturation: 0.62, brightness: 0.38, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: NSRect(origin: .zero, size: size), angle: -90)

        let text = asset.kind == .video ? "▶" : "◍"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: side * 0.22, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let bounds = string.size()
        string.draw(at: NSPoint(x: (size.width - bounds.width) / 2,
                                y: (size.height - bounds.height) / 2))
        return image
    }
}

// MARK: - 可复现随机

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed &* 6_364_136_223_846_793_005 &+ 1 }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func nextInt(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }
}
