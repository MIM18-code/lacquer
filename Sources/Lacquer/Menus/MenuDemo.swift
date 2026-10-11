import CoreGraphics
import CoreText
import Foundation

/// A plain two-level menu drawn with CoreGraphics, for `--menu-demo` and the
/// libbluray check: a main page (Play, Scenes, and Subtitles On/Off when
/// the film has subtitles) and scene pages of up to eight chapter buttons
/// with Back and, when there are more chapters, Next.
enum MenuDemo {
    static let frame = CGSize(width: 1920, height: 1080)
    static let chaptersPerPage = 8

    static func make(title: String, chapterTimes: [Double], subtitles: Bool) -> DiscMenu {
        let chapters = chapterTimes.isEmpty ? [0] : chapterTimes
        let scenePageCount = (chapters.count + chaptersPerPage - 1) / chaptersPerPage

        // ---- Main page.
        var labels = ["Play", "Scenes"]
        var actions: [MenuAction] = [.playFilm, .goToPage(1)]
        if subtitles {
            labels += ["Subtitles On", "Subtitles Off"]
            actions += [.setSubtitles(on: true), .setSubtitles(on: false)]
        }
        let mainRects = labels.indices.map { i in
            CGRect(x: 160, y: 520 + CGFloat(i) * 120, width: 520, height: 96)
        }
        var mainButtons = buttons(rects: mainRects, labels: labels, actions: actions, style: .list)
        link(&mainButtons)
        let main = MenuPage(background: background(title: title, subtitle: "Main menu"), buttons: mainButtons)

        // ---- Scene pages.
        var pages = [main]
        for s in 0..<scenePageCount {
            let range = (s * chaptersPerPage)..<min(chapters.count, (s + 1) * chaptersPerPage)
            var rects: [CGRect] = []
            var tileLabels: [String] = []
            var tileActions: [MenuAction] = []
            for (n, c) in range.enumerated() {
                rects.append(CGRect(x: 160 + CGFloat(n % 4) * 410, y: 380 + CGFloat(n / 4) * 150,
                                    width: 380, height: 120))
                tileLabels.append("Chapter \(c + 1)  \(timeLabel(chapters[c]))")
                tileActions.append(.playChapter(c))
            }
            rects.append(CGRect(x: 160, y: 760, width: 300, height: 96))
            tileLabels.append("Back")
            tileActions.append(.goToPage(0))
            if s + 1 < scenePageCount {
                rects.append(CGRect(x: 490, y: 760, width: 300, height: 96))
                tileLabels.append("Next")
                tileActions.append(.goToPage(2 + s))
            }
            var sceneButtons = buttons(rects: rects, labels: tileLabels, actions: tileActions, style: .tile)
            link(&sceneButtons)
            let heading = scenePageCount > 1 ? "Scenes \(s + 1) of \(scenePageCount)" : "Scenes"
            pages.append(MenuPage(background: background(title: title, subtitle: heading), buttons: sceneButtons))
        }
        return DiscMenu(pages: pages)
    }

    static func timeLabel(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: - Navigation

    /// Points each button's up/down/left/right at the nearest button in that
    /// direction, measured between centres, favouring buttons in line.
    static func link(_ buttons: inout [MenuButton]) {
        let centres = buttons.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) }
        func nearest(from i: Int, dx: CGFloat, dy: CGFloat) -> Int? {
            var best: (Int, CGFloat)?
            for j in buttons.indices where j != i {
                let vx = centres[j].x - centres[i].x, vy = centres[j].y - centres[i].y
                let along = vx * dx + vy * dy
                guard along > 1 else { continue }
                let across = abs(vx * dy - vy * dx)
                let cost = along + 2 * across
                if best == nil || cost < best!.1 { best = (j, cost) }
            }
            return best?.0
        }
        for i in buttons.indices {
            buttons[i].up = nearest(from: i, dx: 0, dy: -1)
            buttons[i].down = nearest(from: i, dx: 0, dy: 1)
            buttons[i].left = nearest(from: i, dx: -1, dy: 0)
            buttons[i].right = nearest(from: i, dx: 1, dy: 0)
        }
    }

    // MARK: - Drawing

    enum Style { case list, tile }

    static func buttons(rects: [CGRect], labels: [String], actions: [MenuAction], style: Style) -> [MenuButton] {
        rects.indices.map { i in
            let size = rects[i].size
            return MenuButton(
                id: i, rect: rects[i],
                normal: buttonImage(size: size, label: labels[i], state: 0, style: style),
                selected: buttonImage(size: size, label: labels[i], state: 1, style: style),
                activated: buttonImage(size: size, label: labels[i], state: 2, style: style),
                action: actions[i])
        }
    }

    /// Normal: translucent dark plate, white text. Selected: amber plate,
    /// dark text. Activated: white plate, dark text.
    static func buttonImage(size: CGSize, label: String, state: Int, style: Style) -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        let ctx = context(width: w, height: h)
        let plate = CGRect(x: 3, y: 3, width: size.width - 6, height: size.height - 6)
        let path = CGPath(roundedRect: plate, cornerWidth: 18, cornerHeight: 18, transform: nil)
        let fill: CGColor, stroke: CGColor, text: CGColor
        switch state {
        case 1:
            fill = CGColor(srgbRed: 0.96, green: 0.72, blue: 0.20, alpha: 1)
            stroke = CGColor(srgbRed: 1, green: 0.9, blue: 0.6, alpha: 1)
            text = CGColor(srgbRed: 0.08, green: 0.06, blue: 0.04, alpha: 1)
        case 2:
            fill = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            stroke = CGColor(srgbRed: 0.96, green: 0.72, blue: 0.20, alpha: 1)
            text = CGColor(srgbRed: 0.08, green: 0.06, blue: 0.04, alpha: 1)
        default:
            fill = CGColor(srgbRed: 0.05, green: 0.07, blue: 0.12, alpha: 0.6)
            stroke = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)
            text = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
        ctx.addPath(path); ctx.setFillColor(fill); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(stroke); ctx.setLineWidth(3); ctx.strokePath()
        drawText(label, in: ctx, size: style == .list ? 40 : 30, color: text,
                 at: CGPoint(x: size.width / 2, y: size.height / 2), centered: true)
        return ctx.makeImage()!
    }

    static func background(title: String, subtitle: String) -> CGImage {
        let w = Int(frame.width), h = Int(frame.height)
        let ctx = context(width: w, height: h)
        let colors = [CGColor(srgbRed: 0.10, green: 0.13, blue: 0.24, alpha: 1),
                      CGColor(srgbRed: 0.02, green: 0.02, blue: 0.04, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: frame.height), end: CGPoint(x: frame.width, y: 0), options: [])
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let grey = CGColor(srgbRed: 0.75, green: 0.78, blue: 0.85, alpha: 1)
        // Context origin is bottom-left; menu coordinates are top-left.
        drawText(title, in: ctx, size: 96, color: white, at: CGPoint(x: 160, y: frame.height - 230), centered: false)
        drawText(subtitle, in: ctx, size: 44, color: grey, at: CGPoint(x: 164, y: frame.height - 310), centered: false)
        return ctx.makeImage()!
    }

    private static func context(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func drawText(_ s: String, in ctx: CGContext, size: CGFloat, color: CGColor,
                                 at point: CGPoint, centered: Bool) {
        let font = CTFontCreateWithName("Helvetica Neue Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let x = centered ? point.x - bounds.width / 2 - bounds.minX : point.x
        let y = centered ? point.y - bounds.height / 2 - bounds.minY : point.y
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }
}
