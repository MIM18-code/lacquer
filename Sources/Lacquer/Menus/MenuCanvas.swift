import AppKit
import CoreGraphics
import CoreImage
import CoreText

// Small drawing layer under the menu renderer: a top-left-origin bitmap
// canvas, CoreText typesetting, and the few image operations menus need.

/// sRGB colour with straight (non-premultiplied) alpha.
struct MenuColor: Equatable, Sendable {
    var r: Double, g: Double, b: Double, a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// 0xRRGGBB
    init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    func with(alpha: Double) -> MenuColor { MenuColor(r, g, b, alpha) }
    func scaled(alpha k: Double) -> MenuColor { MenuColor(r, g, b, a * k) }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    static let black = MenuColor(0, 0, 0)
    static let clear = MenuColor(0, 0, 0, 0)
}

enum MenuImageIO {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func load(_ url: URL, maxPixel: Int = 3840) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// Straight-alpha RGBA bytes, row-major, top row first.
    static func straightRGBA(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Un-premultiply in place.
        bytes.withUnsafeMutableBufferPointer { p in
            var i = 0
            let n = p.count
            while i < n {
                let a = Int(p[i + 3])
                if a == 0 {
                    p[i] = 0; p[i + 1] = 0; p[i + 2] = 0
                } else if a < 255 {
                    for c in 0..<3 {
                        p[i + c] = UInt8(min(255, (Int(p[i + c]) * 255 + a / 2) / a))
                    }
                }
                i += 4
            }
        }
        return bytes
    }

    /// Builds a premultiplied RGBA image from straight-alpha bytes.
    static func image(width: Int, height: Int, straightRGBA bytes: [UInt8]) -> CGImage? {
        var premul = bytes
        premul.withUnsafeMutableBufferPointer { p in
            var i = 0
            let n = p.count
            while i < n {
                let a = Int(p[i + 3])
                if a < 255 {
                    for c in 0..<3 { p[i + c] = UInt8((Int(p[i + c]) * a + 127) / 255) }
                }
                i += 4
            }
        }
        let data = Data(premul) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: srgb,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// A bitmap you draw on with the origin at the top-left, y down.
final class MenuCanvas {
    let width: Int
    let height: Int
    let ctx: CGContext

    /// `opaque` canvases have no alpha channel and start black.
    init(width: Int, height: Int, opaque: Bool) {
        self.width = width
        self.height = height
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: MenuImageIO.srgb, bitmapInfo: info)!
        ctx.interpolationQuality = .high
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false)   // grey-scale AA only: no LCD fringes in video
        ctx.setShouldSmoothFonts(false)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setShouldSubpixelQuantizeFonts(false)
        if opaque {
            ctx.setFillColor(MenuColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
    }

    func makeImage() -> CGImage { ctx.makeImage()! }

    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    // MARK: Shapes

    func fill(_ rect: CGRect, _ color: MenuColor) {
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
    }

    func fillRounded(_ rect: CGRect, radius: CGFloat, _ color: MenuColor) {
        ctx.setFillColor(color.cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    /// Stroke fully inside `rect`.
    func strokeRounded(_ rect: CGRect, radius: CGFloat, width: CGFloat, _ color: MenuColor) {
        let inner = rect.insetBy(dx: width / 2, dy: width / 2)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: max(0, radius - width / 2),
                           cornerHeight: max(0, radius - width / 2), transform: nil))
        ctx.strokePath()
    }

    /// A ring around `inner`: the band between `inner` grown by `gap + width` and `inner` grown by `gap`.
    func ring(around inner: CGRect, gap: CGFloat, width: CGFloat, radius: CGFloat, _ color: MenuColor) {
        let outer = inner.insetBy(dx: -(gap + width), dy: -(gap + width))
        strokeRounded(outer, radius: radius + gap + width, width: width, color)
    }

    func linearGradient(in rect: CGRect, from: CGPoint, to: CGPoint, stops: [(CGFloat, MenuColor)]) {
        let space = MenuImageIO.srgb
        let colors = stops.map { $0.1.cgColor } as CFArray
        let locations = stops.map { $0.0 }
        guard let g = CGGradient(colorsSpace: space, colors: colors, locations: locations) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    func radialGradient(center: CGPoint, radius: CGFloat, scaleY: CGFloat = 1, stops: [(CGFloat, MenuColor)], clip: CGRect) {
        let colors = stops.map { $0.1.cgColor } as CFArray
        let locations = stops.map { $0.0 }
        guard let g = CGGradient(colorsSpace: MenuImageIO.srgb, colors: colors, locations: locations) else { return }
        ctx.saveGState()
        ctx.clip(to: clip)
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: scaleY)
        ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius,
                               options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }

    // MARK: Images

    enum Fit { case fill, fit }

    func draw(_ image: CGImage, in rect: CGRect, fit: Fit, alpha: CGFloat = 1, blend: CGBlendMode = .normal,
              cornerRadius: CGFloat = 0) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return }
        let scale = fit == .fill ? max(rect.width / iw, rect.height / ih) : min(rect.width / iw, rect.height / ih)
        let dw = iw * scale, dh = ih * scale
        let dest = CGRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2, width: dw, height: dh)
        ctx.saveGState()
        if cornerRadius > 0 {
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
            ctx.clip()
        } else {
            ctx.clip(to: rect)
        }
        ctx.setAlpha(alpha)
        ctx.setBlendMode(blend)
        // Flip so the image isn't upside down in our y-down space.
        ctx.translateBy(x: dest.minX, y: dest.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: dw, height: dh))
        ctx.restoreGState()
    }

    // MARK: Text

    /// Draws a typeset block. `rect` is the block's top-left; `align` is
    /// applied per line against `blockWidth` (defaults to the block's own width).
    func draw(_ text: TypeBlock, atX x: CGFloat, top: CGFloat, align: TypeBlock.Align = .left,
              width blockWidth: CGFloat? = nil, color: MenuColor) {
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let w = blockWidth ?? text.width
        for (i, line) in text.lines.enumerated() {
            let dx: CGFloat
            switch align {
            case .left: dx = 0
            case .center: dx = (w - line.width) / 2
            case .right: dx = w - line.width
            }
            ctx.textPosition = CGPoint(x: x + dx, y: top + text.firstAscent + CGFloat(i) * text.pitch)
            CTLineDraw(line.line, ctx)
        }
        ctx.restoreGState()
    }
}

// MARK: - Typesetting

struct MenuFont: Sendable {
    enum Face: Sendable {
        case named(String)
        /// System serif (New York).
        case serif(NSFont.Weight)
        case system(NSFont.Weight)
    }

    var face: Face
    var size: CGFloat

    func ctFont() -> CTFont {
        switch face {
        case .named(let name):
            if let f = NSFont(name: name, size: size) { return f as CTFont }
            return NSFont.systemFont(ofSize: size, weight: .regular) as CTFont
        case .serif(let weight):
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) {
                return f as CTFont
            }
            return (NSFont(name: "Georgia", size: size) ?? base) as CTFont
        case .system(let weight):
            return NSFont.systemFont(ofSize: size, weight: weight) as CTFont
        }
    }

    func sized(_ size: CGFloat) -> MenuFont { MenuFont(face: face, size: size) }
}

struct TypeLine {
    let line: CTLine
    let width: CGFloat
}

/// Laid-out text: wrapped lines plus metrics, ready to measure and draw.
struct TypeBlock {
    enum Align { case left, center, right }

    var lines: [TypeLine]
    var ascent: CGFloat
    var descent: CGFloat
    var capHeight: CGFloat
    /// Distance between baselines.
    var pitch: CGFloat
    var fontSize: CGFloat

    var firstAscent: CGFloat { ascent }
    var width: CGFloat { lines.map(\.width).max() ?? 0 }
    var height: CGFloat {
        guard !lines.isEmpty else { return 0 }
        return ascent + descent + CGFloat(lines.count - 1) * pitch
    }
    var isEmpty: Bool { lines.isEmpty }

    /// Single line, no wrapping.
    static func line(_ text: String, font: MenuFont, tracking: CGFloat = 0) -> TypeBlock {
        layout(text, font: font, tracking: tracking, maxWidth: nil, lineHeight: 1.2)
    }

    static func layout(_ text: String, font: MenuFont, tracking: CGFloat = 0, maxWidth: CGFloat?,
                       lineHeight: CGFloat) -> TypeBlock {
        let ct = font.ctFont()
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): ct,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        let ascent = CTFontGetAscent(ct), descent = CTFontGetDescent(ct), capHeight = CTFontGetCapHeight(ct)
        var lines: [TypeLine] = []
        // Honour explicit newlines, then wrap each paragraph.
        for paragraph in text.components(separatedBy: .newlines) where !paragraph.isEmpty {
            let str = NSAttributedString(string: paragraph, attributes: attrs)
            let typesetter = CTTypesetterCreateWithAttributedString(str)
            var start = 0
            let length = str.length
            while start < length {
                var count = length - start
                if let maxWidth {
                    count = CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth))
                    if count < 1 { count = 1 }
                }
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                var w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                // Trailing whitespace and the last glyph's tracking aren't ink.
                w -= CGFloat(CTLineGetTrailingWhitespaceWidth(line))
                w -= tracking
                lines.append(TypeLine(line: line, width: max(0, w)))
                start += count
            }
        }
        return TypeBlock(lines: lines, ascent: ascent, descent: descent, capHeight: capHeight,
                         pitch: font.size * lineHeight, fontSize: font.size)
    }

    /// Fits `text` in `maxWidth`, at most `maxLines` lines and `maxHeight`
    /// tall. Shrinks the font down to `minSize` first. If it still doesn't
    /// fit, cuts the text and ends it with an ellipsis, so the result always
    /// stays inside the limits however long the text is.
    static func fitting(_ text: String, font: MenuFont, tracking: CGFloat, trackingScalesWithSize: Bool = true,
                        maxWidth: CGFloat, maxHeight: CGFloat, maxLines: Int, minSize: CGFloat,
                        lineHeight: CGFloat) -> TypeBlock {
        func fits(_ b: TypeBlock) -> Bool {
            b.lines.count <= max(1, maxLines) && b.height <= maxHeight + 0.01 && b.width <= maxWidth + 0.5
        }
        var size = font.size
        var currentTracking = tracking
        var block = layout(text, font: font, tracking: tracking, maxWidth: maxWidth, lineHeight: lineHeight)
        while size > minSize, !fits(block) {
            size = max(minSize, size - 4)
            currentTracking = trackingScalesWithSize ? tracking * size / font.size : tracking
            block = layout(text, font: font.sized(size), tracking: currentTracking, maxWidth: maxWidth, lineHeight: lineHeight)
        }
        if fits(block) { return block }

        // Still too big at the smallest size: keep the longest prefix that fits with an ellipsis.
        let chars = Array(text)
        let sized = font.sized(size)
        func candidate(_ k: Int) -> TypeBlock {
            let head = String(chars[0..<k]).trimmingCharacters(in: .whitespacesAndNewlines)
            return layout(head + "\u{2026}", font: sized, tracking: currentTracking, maxWidth: maxWidth, lineHeight: lineHeight)
        }
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fits(candidate(mid)) { lo = mid } else { hi = mid - 1 }
        }
        return candidate(lo)
    }
}

// MARK: - Image effects

enum MenuImageOps {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Gaussian blur at full size; works from a downscaled copy so it stays cheap.
    static func blurred(_ image: CGImage, width: Int, height: Int, sigma: CGFloat) -> CGImage {
        // Draw cover-fit into a small canvas, blur, and scale back up.
        let sw = max(48, width / 6), sh = max(27, height / 6)
        let small = MenuCanvas(width: sw, height: sh, opaque: true)
        small.draw(image, in: small.bounds, fit: .fill)
        let ci = CIImage(cgImage: small.makeImage())
        let blurredCI = ci.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(sigma) * Double(sw) / Double(width))
            .cropped(to: ci.extent)
        let blurredImage = ciContext.createCGImage(blurredCI, from: ci.extent, format: .RGBA8,
                                                   colorSpace: MenuImageIO.srgb) ?? small.makeImage()
        let big = MenuCanvas(width: width, height: height, opaque: true)
        big.draw(blurredImage, in: big.bounds, fit: .fill)
        return big.makeImage()
    }
}
