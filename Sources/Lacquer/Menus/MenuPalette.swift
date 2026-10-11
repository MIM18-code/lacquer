import CoreGraphics
import Foundation

/// HDMV menu overlays share one 256-entry palette per page, each entry a
/// colour plus alpha. Entry 255 is reserved, so we aim for at most 255
/// including transparent.
enum MenuPalette {
    static let maxEntries = 255

    /// Alpha is snapped to multiples of 17 (16 levels, 0...255).
    static let alphaLevels = 16

    // MARK: Counting

    /// Distinct RGBA values across every state image of every button on a
    /// page. All fully transparent pixels count as one entry.
    static func colorCount(of menu: DiscMenu, page: Int) -> Int {
        colorCount(of: menu.pages[page])
    }

    static func colorCount(of page: MenuPage) -> Int {
        colorCount(of: page.buttons.flatMap { [$0.normal, $0.selected, $0.activated] })
    }

    static func colorCount(of images: [CGImage]) -> Int {
        var seen = Set<UInt32>()
        for image in images {
            let bytes = MenuImageIO.straightRGBA(image)
            bytes.withUnsafeBufferPointer { p in
                var i = 0
                var last: UInt32 = 0xFFFF_FFFF
                while i < p.count {
                    let a = UInt32(p[i + 3])
                    let key = a == 0 ? 0 : UInt32(p[i]) << 24 | UInt32(p[i + 1]) << 16 | UInt32(p[i + 2]) << 8 | a
                    if key != last { seen.insert(key); last = key }
                    i += 4
                }
            }
        }
        return seen.count
    }

    // MARK: Quantizing

    /// Reduces a set of images that will share one palette to at most
    /// `maxEntries` colours. Alpha snaps to 16 levels; RGB collapses onto
    /// at most `(maxEntries - 1) / (alphaLevels - 1)` base colours chosen by
    /// weight, which for flat designs with anti-aliased edges loses nothing
    /// you can see. Images keep their sizes.
    static func reduce(_ images: [CGImage], maxEntries: Int = MenuPalette.maxEntries) -> [CGImage] {
        let baseColorLimit = max(1, (maxEntries - 1) / (alphaLevels - 1))
        let decoded = images.map { MenuImageIO.straightRGBA($0) }

        // Weight each RGB by alpha² over pixels solid enough to trust their colour.
        var weights: [UInt32: Double] = [:]
        for bytes in decoded {
            bytes.withUnsafeBufferPointer { p in
                var i = 0
                // Runs of one colour (fills, the veil) are common: batch them.
                var runKey: UInt32 = 0, runWeight = 0.0
                while i < p.count {
                    let a = Int(p[i + 3])
                    if a >= 64 {
                        let key = UInt32(p[i]) << 16 | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2])
                        if key != runKey {
                            if runWeight > 0 { weights[runKey, default: 0] += runWeight }
                            runKey = key; runWeight = 0
                        }
                        runWeight += Double(a * a)
                    }
                    i += 4
                }
                if runWeight > 0 { weights[runKey, default: 0] += runWeight }
            }
        }
        // Leader clustering, heaviest colour first: a colour within 12 RGB
        // units of an existing centre joins it. Rounding noise at low alpha
        // lands here and merges into its real colour.
        let sorted = weights.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
        var centres: [(r: Int, g: Int, b: Int)] = []
        for (key, _) in sorted {
            let c = unpack(key)
            if centres.contains(where: { distance($0, c) <= 12 * 12 }) { continue }
            if centres.count < baseColorLimit { centres.append(c) }
        }
        if centres.isEmpty { centres = [(255, 255, 255)] }

        var nearestCache: [UInt32: Int] = [:]
        func nearest(_ key: UInt32) -> Int {
            if let hit = nearestCache[key] { return hit }
            let c = unpack(key)
            var best = 0, bestD = Int.max
            for (idx, centre) in centres.enumerated() {
                let d = distance(centre, c)
                if d < bestD { bestD = d; best = idx }
            }
            nearestCache[key] = best
            return best
        }

        return zip(images, decoded).map { image, bytes in
            var out = bytes
            out.withUnsafeMutableBufferPointer { p in
                var i = 0
                var lastKey: UInt32 = .max
                var lastCentre = centres[0]
                while i < p.count {
                    let a = Int(p[i + 3])
                    let level = (a * (alphaLevels - 1) + 127) / 255
                    if level == 0 {
                        p[i] = 0; p[i + 1] = 0; p[i + 2] = 0; p[i + 3] = 0
                    } else {
                        let key = UInt32(p[i]) << 16 | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2])
                        if key != lastKey { lastKey = key; lastCentre = centres[nearest(key)] }
                        let c = lastCentre
                        p[i] = UInt8(c.r); p[i + 1] = UInt8(c.g); p[i + 2] = UInt8(c.b)
                        p[i + 3] = UInt8(level * 255 / (alphaLevels - 1))
                    }
                    i += 4
                }
            }
            return MenuImageIO.image(width: image.width, height: image.height, straightRGBA: out) ?? image
        }
    }

    private static func unpack(_ key: UInt32) -> (r: Int, g: Int, b: Int) {
        (Int(key >> 16 & 0xFF), Int(key >> 8 & 0xFF), Int(key & 0xFF))
    }

    private static func distance(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int)) -> Int {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return dr * dr + dg * dg + db * db
    }
}
