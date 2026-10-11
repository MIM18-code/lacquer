import CoreGraphics
import Foundation

/// One segment of an Interactive Graphics stream, carried in its own PES
/// packet. `bytes` include the 3-byte segment header (type, length).
struct IGSegment: Sendable {
    enum Kind: Equatable, Sendable {
        case composition
        case palette
        /// One fragment of an object definition; `pixels` is the object's
        /// width × height, for its decode time.
        case object(id: Int, pixels: Int, lastFragment: Bool)
        case end
    }

    var kind: Kind
    var bytes: [UInt8]
    /// 90 kHz.
    var pts: Int64 = 0
    var dts: Int64 = 0

    /// Palette and end segments carry only a PTS, as in tsMuxeR's PG output.
    var hasDTS: Bool {
        switch kind {
        case .composition, .object: return true
        case .palette, .end: return false
        }
    }
}

/// An epoch-start display set: the interactive composition (one page), its
/// palette, every button state as an object, and the end segment.
struct IGDisplaySet: Sendable {
    var segments: [IGSegment]

    /// Offset of composition_timeout_pts inside the ICS segment: header (3),
    /// video descriptor (5), composition descriptor (3), sequence
    /// descriptor (1), data length (3), model flags (1).
    static let timeoutOffset = 16

    /// Decode and presentation times from the 90 kHz times at which each
    /// segment has fully arrived. Objects decode one after another; the
    /// composition is presented once the plane is cleared and every object
    /// is decoded. Returns the composition's PTS.
    mutating func assignTimestamps(arrivals90k: [Int64]) -> Int64 {
        let compositionDTS = arrivals90k[0]
        var decodedBy = compositionDTS
        var objectDTS: Int64 = 0
        for i in segments.indices {
            switch segments[i].kind {
            case .composition:
                segments[i].dts = compositionDTS
            case .palette:
                segments[i].pts = max(arrivals90k[i], compositionDTS)
            case .object(_, let pixels, _):
                // Every fragment carries the timestamps of the whole object,
                // which can only start decoding once its last fragment is in.
                if !isFragmentContinuation(i) {
                    objectDTS = max(arrivals90k[lastFragmentIndex(from: i)], decodedBy)
                    decodedBy = objectDTS + Self.objectDecodeTicks(pixels: pixels)
                }
                segments[i].dts = objectDTS
                segments[i].pts = decodedBy
            case .end:
                segments[i].pts = max(decodedBy, arrivals90k[i])
                decodedBy = segments[i].pts
            }
        }
        let compositionPTS = max(compositionDTS + Self.planeClearTicks, decodedBy)
        segments[0].pts = compositionPTS
        return compositionPTS
    }

    mutating func setCompositionPTS(_ pts: Int64) {
        if let i = segments.firstIndex(where: { $0.kind == .composition }) { segments[i].pts = pts }
    }

    /// Composition and selection time-outs: the menu stays valid until the
    /// end of the clip.
    mutating func setTimeouts(_ pts90k: Int64) {
        guard let i = segments.firstIndex(where: { $0.kind == .composition }) else { return }
        let v = UInt64(bitPattern: pts90k) & 0x1_FFFF_FFFF
        for field in 0..<2 {
            let at = Self.timeoutOffset + field * 5
            for b in 0..<5 {
                segments[i].bytes[at + b] = UInt8((v >> UInt64(8 * (4 - b))) & 0xFF)
            }
        }
    }

    private func isFragmentContinuation(_ i: Int) -> Bool {
        guard i > 0, case .object(let id, _, _) = segments[i].kind,
              case .object(let prevID, _, let prevLast) = segments[i - 1].kind else { return false }
        return id == prevID && !prevLast
    }

    private func lastFragmentIndex(from i: Int) -> Int {
        var j = i
        while case .object(_, _, let last) = segments[j].kind, !last, j + 1 < segments.count { j += 1 }
        return j
    }

    /// Clearing the 1920×1080 graphics plane at epoch start, with room to
    /// spare: twice the PG figure of 1920 × 1080 × 9 / 3200 ticks.
    static let planeClearTicks: Int64 = 11_664

    /// Object decoding at 8 Mpixel/s, a conservative reading of the IG
    /// decoder rate.
    static func objectDecodeTicks(pixels: Int) -> Int64 {
        Int64((pixels * 9 + 799) / 800)
    }
}

/// Builds the IG display set for one menu page.
///
/// Every button lives in its own button overlap group (BOG), so each draws
/// independently. Button ids are their index in `MenuPage.buttons`; each
/// button state is one object. All of a page's overlays share one palette
/// of up to 255 colours plus transparent entry 0.
enum IGSEncoder {
    struct Button {
        var rect: CGRect
        var normal: CGImage
        var selected: CGImage
        var activated: CGImage
        var up: Int, down: Int, left: Int, right: Int
        var commands: [NavCommand]
    }

    enum EncodeError: LocalizedError {
        case tooManyButtons(Int)
        case compositionTooLarge(Int)
        case badButtonImage(Int, String)

        var errorDescription: String? {
            switch self {
            case .tooManyButtons(let n): return "A menu page has \(n) buttons; HDMV allows 255 per page."
            case .compositionTooLarge(let n): return "A menu page's button table is \(n) bytes, more than one segment holds."
            case .badButtonImage(let i, let why): return "Menu button \(i + 1): \(why)."
            }
        }
    }

    /// `frameRateCode` 1 = 23.976 (the menu clip's video rate). A nil
    /// `defaultButton` leaves the choice to the selection the movie object
    /// stored (PSR10).
    static func displaySet(buttons: [Button], defaultButton: Int?,
                           width: Int = 1920, height: Int = 1080, frameRateCode: Int = 1) throws -> IGDisplaySet {
        guard buttons.count <= 255 else { throw EncodeError.tooManyButtons(buttons.count) }

        // ---- Pixels of every state image, then one palette for the page.
        var images: [RGBAImage] = []
        for (i, b) in buttons.enumerated() {
            let w = Int(b.rect.width.rounded()), h = Int(b.rect.height.rounded())
            guard w > 0, h > 0, w <= 4096, h <= 4096 else {
                throw EncodeError.badButtonImage(i, "size \(w)×\(h) is outside 1–4096 pixels")
            }
            guard b.rect.minX >= 0, b.rect.minY >= 0, Int(b.rect.maxX.rounded()) <= width, Int(b.rect.maxY.rounded()) <= height else {
                throw EncodeError.badButtonImage(i, "its rectangle runs off the \(width)×\(height) frame")
            }
            for image in [b.normal, b.selected, b.activated] {
                guard image.width == w, image.height == h else {
                    throw EncodeError.badButtonImage(i, "a state image is \(image.width)×\(image.height), not \(w)×\(h)")
                }
                images.append(RGBAImage(image))
            }
        }
        var palette = PaletteQuantizer.palette(for: images)

        // ---- Objects: ids 3i, 3i+1, 3i+2 for normal, selected, activated.
        var objectSegments: [IGSegment] = []
        for (n, image) in images.enumerated() {
            let rle = RLE.encode(palette.indices(for: image), width: image.width, height: image.height)
            objectSegments += objectDefinition(id: n, width: image.width, height: image.height, rle: rle)
        }

        // ---- Composition.
        var c = ByteWriter()
        c.u16(width); c.u16(height)
        c.u8(frameRateCode << 4)
        c.u16(0)                    // composition_number
        c.u8(0x80)                  // composition_state: epoch start
        c.u8(0xC0)                  // first and last in sequence
        let dataLength = c.reserve(3)
        c.u8(0x00)                  // stream_model 0 (multiplexed), ui_model 0 (always on)
        c.zeros(5)                  // composition_timeout_pts, set by the muxer
        c.zeros(5)                  // selection_timeout_pts
        c.u24(0)                    // user_timeout_duration: none
        c.u8(1)                     // number_of_pages
        c.u8(0)                     // page_id
        c.u8(0)                     // page_version_number
        c.zeros(8)                  // UO mask: allow everything
        c.u8(0); c.u8(0)            // in effects: no windows, no effects
        c.u8(0); c.u8(0)            // out effects
        c.u8(0)                     // animation_frame_rate_code
        c.u16(defaultButton ?? 0xFFFF)  // default_selected_button_id_ref
        c.u16(0xFFFF)               // default_activated_button_id_ref: none
        c.u8(0)                     // palette_id_ref
        c.u8(buttons.count)         // number_of_BOGs
        for (i, b) in buttons.enumerated() {
            c.u16(i)                // default_valid_button_id_ref
            c.u8(1)                 // number_of_buttons
            c.u16(i)                // button_id
            c.u16(0xFFFF)           // button_numeric_select_value: none
            c.u8(0)                 // auto_action_flag 0
            c.u16(Int(b.rect.minX.rounded())); c.u16(Int(b.rect.minY.rounded()))
            c.u16(b.up); c.u16(b.down); c.u16(b.left); c.u16(b.right)
            c.u16(3 * i); c.u16(3 * i); c.u8(0)                     // normal
            c.u8(0xFF); c.u16(3 * i + 1); c.u16(3 * i + 1); c.u8(0) // selected, no sound
            c.u8(0xFF); c.u16(3 * i + 2); c.u16(3 * i + 2)          // activated
            c.u16(b.commands.count)
            for cmd in b.commands { c.append(cmd.bytes) }
        }
        c.patchLength(at: dataLength, width: 3)

        guard c.count <= maxSegmentBody else { throw EncodeError.compositionTooLarge(c.count) }
        var segments = [segment(0x18, c.bytes, .composition)]
        segments.append(segment(0x14, palette.definition(), .palette))
        segments += objectSegments
        segments.append(segment(0x80, [], .end))
        return IGDisplaySet(segments: segments)
    }

    private static func segment(_ type: UInt8, _ body: [UInt8], _ kind: IGSegment.Kind) -> IGSegment {
        IGSegment(kind: kind, bytes: [type, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body)
    }

    /// Largest segment body that still fits one PES packet with PTS and DTS.
    static let maxSegmentBody = 0xFFFF - 3 - 10 - 3

    /// An object definition, split into fragments when its RLE data doesn't
    /// fit one segment.
    static func objectDefinition(id: Int, width: Int, height: Int, rle: [UInt8]) -> [IGSegment] {
        var payload = ByteWriter()
        payload.u24(rle.count + 4)  // object_data_length counts width and height
        payload.u16(width); payload.u16(height)
        payload.append(rle)
        let data = payload.bytes
        var segments: [IGSegment] = []
        var offset = 0
        let chunk = maxSegmentBody - 4
        repeat {
            let end = min(offset + chunk, data.count)
            let first = offset == 0, last = end == data.count
            var body = ByteWriter()
            body.u16(id); body.u8(0)    // object_id, object_version_number
            body.u8((first ? 0x80 : 0) | (last ? 0x40 : 0))
            body.append(Array(data[offset..<end]))
            segments.append(segment(0x15, body.bytes, .object(id: id, pixels: width * height, lastFragment: last)))
            offset = end
        } while offset < data.count
        return segments
    }
}

/// Straight (non-premultiplied) RGBA pixels of a CGImage.
struct RGBAImage {
    var width: Int
    var height: Int
    /// r, g, b, a per pixel, row by row from the top.
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.pixels = pixels
    }

    init(_ image: CGImage) {
        let width = image.width, height = image.height
        self.width = width
        self.height = height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        buffer.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: width * 4, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        for i in stride(from: 0, to: buffer.count, by: 4) {
            let a = Int(buffer[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { buffer[i + c] = UInt8(min(255, (Int(buffer[i + c]) * 255 + a / 2) / a)) }
        }
        pixels = buffer
    }
}

/// A palette of at most 255 opaque-or-translucent colours plus fully
/// transparent entry 0, and the lookup from RGBA to entry.
struct IGPalette {
    /// RGBA of entries 1...count.
    var colors: [[UInt8]]
    private var lookup: [UInt32: UInt8] = [:]

    /// Alpha at or below this is treated as fully transparent.
    static let transparentAlpha: UInt8 = 8

    init(colors: [[UInt8]]) { self.colors = colors }

    mutating func indices(for image: RGBAImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: image.width * image.height)
        let p = image.pixels
        for i in 0..<out.count {
            let a = p[i * 4 + 3]
            if a <= Self.transparentAlpha { continue }
            let key = UInt32(p[i * 4]) << 24 | UInt32(p[i * 4 + 1]) << 16 | UInt32(p[i * 4 + 2]) << 8 | UInt32(a)
            if let hit = lookup[key] { out[i] = hit; continue }
            let index = nearest(p[i * 4], p[i * 4 + 1], p[i * 4 + 2], a)
            lookup[key] = index
            out[i] = index
        }
        return out
    }

    private func nearest(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> UInt8 {
        var best = 0, bestDistance = Int.max
        for (i, c) in colors.enumerated() {
            let dr = Int(c[0]) - Int(r), dg = Int(c[1]) - Int(g), db = Int(c[2]) - Int(b), da = Int(c[3]) - Int(a)
            let d = 2 * dr * dr + 4 * dg * dg + db * db + 3 * da * da
            if d < bestDistance { bestDistance = d; best = i }
        }
        return UInt8(best + 1)
    }

    /// Palette definition segment body: palette 0, version 0, then
    /// (entry, Y, Cr, Cb, T) for every entry, in BT.709 limited range.
    func definition() -> [UInt8] {
        var w = ByteWriter()
        w.u8(0); w.u8(0)
        w.append([0, 16, 128, 128, 0])
        for (i, c) in colors.enumerated() {
            let (y, cb, cr) = Self.ycbcr709(c[0], c[1], c[2])
            w.append([UInt8(i + 1), y, cr, cb, c[3]])
        }
        return w.bytes
    }

    static func ycbcr709(_ r8: UInt8, _ g8: UInt8, _ b8: UInt8) -> (UInt8, UInt8, UInt8) {
        let r = Double(r8) / 255, g = Double(g8) / 255, b = Double(b8) / 255
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let cb = (b - y) / 1.8556
        let cr = (r - y) / 1.5748
        func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        return (clamp(16 + 219 * y), clamp(128 + 224 * cb), clamp(128 + 224 * cr))
    }
}

/// Median-cut colour reduction over every overlay on a page. Pages with
/// 255 or fewer distinct colours keep them exactly.
enum PaletteQuantizer {
    static func palette(for images: [RGBAImage], maxColors: Int = 255) -> IGPalette {
        var histogram: [UInt32: Int] = [:]
        for image in images {
            let p = image.pixels
            for i in stride(from: 0, to: p.count, by: 4) where p[i + 3] > IGPalette.transparentAlpha {
                let key = UInt32(p[i]) << 24 | UInt32(p[i + 1]) << 16 | UInt32(p[i + 2]) << 8 | UInt32(p[i + 3])
                histogram[key, default: 0] += 1
            }
        }
        func rgba(_ k: UInt32) -> [Int] { [Int(k >> 24), Int((k >> 16) & 0xFF), Int((k >> 8) & 0xFF), Int(k & 0xFF)] }
        let entries = histogram.map { (color: rgba($0.key), count: $0.value) }
        if entries.count <= maxColors {
            return IGPalette(colors: entries.sorted { $0.count > $1.count }.map { $0.color.map(UInt8.init) })
        }

        var boxes: [[(color: [Int], count: Int)]] = [entries]
        while boxes.count < maxColors {
            // Split the box with the widest weighted channel range.
            var bestBox = -1, bestChannel = 0, bestScore = 0
            for (bi, box) in boxes.enumerated() where box.count > 1 {
                let weight = box.reduce(0) { $0 + $1.count }
                for ch in 0..<4 {
                    let values = box.map { $0.color[ch] }
                    let range = (values.max() ?? 0) - (values.min() ?? 0)
                    let score = range * Int(Double(weight).squareRoot())
                    if score > bestScore { bestScore = score; bestBox = bi; bestChannel = ch }
                }
            }
            if bestBox < 0 { break }
            let sorted = boxes[bestBox].sorted { $0.color[bestChannel] < $1.color[bestChannel] }
            let total = sorted.reduce(0) { $0 + $1.count }
            var running = 0, cut = 1
            for (i, e) in sorted.enumerated() {
                running += e.count
                if running * 2 >= total { cut = max(1, min(sorted.count - 1, i + 1)); break }
            }
            boxes[bestBox] = Array(sorted[..<cut])
            boxes.append(Array(sorted[cut...]))
        }
        let colors: [[UInt8]] = boxes.map { box in
            let weight = max(1, box.reduce(0) { $0 + $1.count })
            return (0..<4).map { ch in
                UInt8((box.reduce(0) { $0 + $1.color[ch] * $1.count } + weight / 2) / weight)
            }
        }
        return IGPalette(colors: colors)
    }
}

/// HDMV graphics run-length coding (libbluray `pg_decode.c` `_decode_rle`).
enum RLE {
    static func encode(_ indices: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(indices.count / 4)
        for y in 0..<height {
            var x = 0
            let row = y * width
            while x < width {
                let color = indices[row + x]
                var run = 1
                while x + run < width, indices[row + x + run] == color, run < 16_383 { run += 1 }
                appendRun(&out, color: color, length: run)
                x += run
            }
            out += [0, 0]           // end of line
        }
        return out
    }

    private static func appendRun(_ out: inout [UInt8], color: UInt8, length: Int) {
        if color == 0 {
            if length < 64 {
                out += [0, UInt8(length)]
            } else {
                out += [0, 0x40 | UInt8(length >> 8), UInt8(length & 0xFF)]
            }
        } else if length < 3 {
            out += [UInt8](repeating: color, count: length)
        } else if length < 64 {
            out += [0, 0x80 | UInt8(length), color]
        } else {
            out += [0, 0xC0 | UInt8(length >> 8), UInt8(length & 0xFF), color]
        }
    }

    /// Inverse of `encode`, for tests.
    static func decode(_ data: [UInt8], width: Int, height: Int) -> [UInt8]? {
        var out: [UInt8] = []
        var i = 0
        while i < data.count {
            let b = data[i]; i += 1
            if b != 0 { out.append(b); continue }
            guard i < data.count else { return nil }
            let f = data[i]; i += 1
            if f == 0 { continue }  // end of line
            var length = Int(f & 0x3F)
            if f & 0x40 != 0 { guard i < data.count else { return nil }; length = length << 8 | Int(data[i]); i += 1 }
            var color: UInt8 = 0
            if f & 0x80 != 0 { guard i < data.count else { return nil }; color = data[i]; i += 1 }
            out += [UInt8](repeating: color, count: length)
        }
        return out.count == width * height ? out : nil
    }
}
