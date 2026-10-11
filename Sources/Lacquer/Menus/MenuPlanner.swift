import CoreGraphics
import Foundation

// Layout without drawing: which pages exist, where every button and line of
// text sits, and how the remote moves between buttons. Pure geometry, so
// the tests check safe areas and paging without touching ffmpeg or pixels.

struct MenuNeighbours: Equatable, Sendable {
    var up: Int?
    var down: Int?
    var left: Int?
    var right: Int?
}

struct PlannedButton: Sendable {
    enum Content: Sendable {
        case text(String)
        /// A chapter tile: `thumb` is the picture's rect on the frame (not
        /// inside the button), `scene` and `time` make up the label.
        case scene(chapter: Int, thumb: CGRect, scene: String, time: String?)
    }
    var rect: CGRect
    var content: Content
    var action: MenuAction
}

/// A line or block of text that is part of the background (not a button).
struct PlacedText: Sendable {
    enum Role: Sendable { case title, subtitle, header, indicator }
    var role: Role
    var block: TypeBlock
    /// Left edge of the region the block is aligned in.
    var x: CGFloat
    var top: CGFloat
    /// Width of that region.
    var width: CGFloat
    var align: TypeBlock.Align

    var bounds: CGRect {
        let w = block.width
        let left: CGFloat
        switch align {
        case .left: left = x
        case .center: left = x + (width - w) / 2
        case .right: left = x + width - w
        }
        return CGRect(x: left, y: top, width: w, height: block.height)
    }
}

struct PlannedDecor: Sendable {
    enum Role: Sendable { case accentBar, hairline }
    var role: Role
    var rect: CGRect
}

struct PlannedPage: Sendable {
    enum Kind: Equatable, Sendable {
        case main
        /// `index` counts from 0; `firstChapter` is the chapter in the first tile.
        case scenes(index: Int, of: Int, firstChapter: Int, count: Int)
    }
    var kind: Kind
    var buttons: [PlannedButton]
    var neighbours: [MenuNeighbours]
    var texts: [PlacedText]
    var decor: [PlannedDecor]
    var defaultButton: Int = 0
}

struct MenuPlan: Sendable {
    var style: MenuStyle
    var pages: [PlannedPage]
    var hasScenes: Bool
    var hasSubtitles: Bool
    var scenePageCount: Int { pages.count - 1 }
}

// MARK: - Navigation

enum MenuNavigation {
    /// Picks, for each button and direction, the nearest button that lies
    /// that way. Left and right only reach buttons on the same row (so a
    /// tile on the row above doesn't count); up and down take anything
    /// above or below, preferring the one most directly in line.
    static func neighbours(for rects: [CGRect]) -> [MenuNeighbours] {
        rects.indices.map { i in
            var n = MenuNeighbours()
            let c = center(rects[i])
            var best: [Direction: (score: CGFloat, index: Int)] = [:]
            for j in rects.indices where j != i {
                let d = center(rects[j])
                let dx = d.x - c.x, dy = d.y - c.y
                // Sideways moves stay on the same row: the rects must share some height.
                let sameRow = rects[i].minY < rects[j].maxY && rects[j].minY < rects[i].maxY
                if dx > 1, sameRow { consider(.right, dx + 2 * abs(dy), j, &best) }
                if dx < -1, sameRow { consider(.left, -dx + 2 * abs(dy), j, &best) }
                if dy > 1 { consider(.down, dy + 3 * abs(dx), j, &best) }
                if dy < -1 { consider(.up, -dy + 3 * abs(dx), j, &best) }
            }
            n.right = best[.right]?.index
            n.left = best[.left]?.index
            n.down = best[.down]?.index
            n.up = best[.up]?.index
            return n
        }
    }

    private enum Direction { case up, down, left, right }

    private static func consider(_ d: Direction, _ score: CGFloat, _ j: Int,
                                 _ best: inout [Direction: (score: CGFloat, index: Int)]) {
        if let current = best[d], current.score <= score { return }
        best[d] = (score, j)
    }

    private static func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
}

// MARK: - Planner

enum MenuPlanner {
    static func plan(template: MenuTemplate, chapters: [Double], hasSubtitles: Bool) -> MenuPlan {
        let style = MenuStyle.style(for: template.style)
        let settings = template.scenePages.clamped
        let showScenes = template.includeScenes && chapters.count >= 2
        let showSubtitles = template.includeSubtitles && hasSubtitles
        let perPage = settings.perPage
        let sceneCount = showScenes ? chapters.count : 0
        let pageCount = showScenes ? (sceneCount + perPage - 1) / perPage : 0

        var pages = [mainPage(template: template, style: style, showScenes: showScenes, showSubtitles: showSubtitles)]
        for p in 0..<pageCount {
            pages.append(scenesPage(index: p, of: pageCount, chapters: chapters, settings: settings, style: style,
                                    name: template.sceneName))
        }
        return MenuPlan(style: style, pages: pages, hasScenes: showScenes, hasSubtitles: showSubtitles)
    }

    static func timeString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: Main page

    private static func mainPage(template: MenuTemplate, style: MenuStyle, showScenes: Bool, showSubtitles: Bool) -> PlannedPage {
        var items: [(String, MenuAction)] = [("Play", .playFilm)]
        if showScenes { items.append(("Scenes", .goToPage(1))) }
        if showSubtitles {
            items.append(("Subtitles On", .setSubtitles(on: true)))
            items.append(("Subtitles Off", .setSubtitles(on: false)))
        }
        let blocks = items.map { style.buttonBlock($0.0) }
        let sizes = blocks.map { style.buttonSize(for: $0) }
        var rects: [CGRect] = []
        var texts: [PlacedText] = []
        var decor: [PlannedDecor] = []

        let titleString = template.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitleString = template.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)

        func titleBlock(width: CGFloat, height: CGFloat, maxLines: Int, minSize: CGFloat, align: TypeBlock.Align) -> TypeBlock? {
            guard !titleString.isEmpty else { return nil }
            return TypeBlock.fitting(style.titleUppercase ? titleString.uppercased() : titleString,
                                     font: style.titleFont, tracking: style.titleTracking,
                                     maxWidth: width, maxHeight: height, maxLines: maxLines, minSize: minSize,
                                     lineHeight: style.titleLineHeight)
        }
        func subtitleBlock(width: CGFloat) -> TypeBlock? {
            guard !subtitleString.isEmpty else { return nil }
            return TypeBlock.fitting(style.subtitleUppercase ? subtitleString.uppercased() : subtitleString,
                                     font: style.subtitleFont, tracking: style.subtitleTracking,
                                     maxWidth: width, maxHeight: 80, maxLines: 1, minSize: 32, lineHeight: 1.2)
        }

        switch style.mainLayout {
        case .lowerLeftRow:
            let rowH = sizes.map(\.height).max() ?? 0
            let y = MenuGeometry.titleSafe.maxY - rowH
            var x = MenuGeometry.titleSafe.minX
            for s in sizes {
                rects.append(CGRect(x: x, y: y, width: s.width, height: s.height))
                x += s.width + 64
            }
            var cursor = y - 44
            if let sub = subtitleBlock(width: 1300) {
                let top = cursor - sub.height
                texts.append(PlacedText(role: .subtitle, block: sub, x: MenuGeometry.titleSafe.minX, top: top, width: 1300, align: .left))
                cursor = top - 22
            }
            if let title = titleBlock(width: 1300, height: 330, maxLines: 3, minSize: 56, align: .left) {
                texts.append(PlacedText(role: .title, block: title, x: MenuGeometry.titleSafe.minX,
                                        top: cursor - title.height, width: 1300, align: .left))
            }

        case .centredCard:
            // Letterbox band is 84...887; buttons sit in the bar below it.
            let rowH = sizes.map(\.height).max() ?? 0
            let gap: CGFloat = 24
            let total = sizes.map(\.width).reduce(0, +) + gap * CGFloat(max(0, sizes.count - 1))
            var x = (960 - total / 2).rounded()
            let y = min(MenuGeometry.titleSafe.maxY - rowH, (934 - rowH / 2).rounded())
            for s in sizes {
                rects.append(CGRect(x: x, y: y, width: s.width, height: s.height))
                x += s.width + gap
            }
            let regionX: CGFloat = 960 - 660, regionW: CGFloat = 1320
            let title = titleBlock(width: regionW, height: 300, maxLines: 2, minSize: 52, align: .center)
            let sub = subtitleBlock(width: regionW)
            if title != nil || sub != nil {
                // rule, title, subtitle, rule, centred on the letterbox band.
                let ruleH: CGFloat = 3, ruleGap: CGFloat = 40, innerGap: CGFloat = 28
                let stackH = ruleH + ruleGap + (title?.height ?? 0) + (title != nil && sub != nil ? innerGap : 0)
                    + (sub?.height ?? 0) + ruleGap + ruleH
                var top = (485 - stackH / 2).rounded()
                decor.append(PlannedDecor(role: .accentBar, rect: CGRect(x: 900, y: top, width: 120, height: ruleH)))
                top += ruleH + ruleGap
                if let title {
                    texts.append(PlacedText(role: .title, block: title, x: regionX, top: top, width: regionW, align: .center))
                    top += title.height + innerGap
                }
                if let sub {
                    texts.append(PlacedText(role: .subtitle, block: sub, x: regionX, top: top, width: regionW, align: .center))
                    top += sub.height
                } else {
                    top -= innerGap
                }
                top += ruleGap
                decor.append(PlannedDecor(role: .accentBar, rect: CGRect(x: 900, y: top, width: 120, height: ruleH)))
            }

        case .leftColumn:
            let pitchGap: CGFloat = 14
            var y = MenuGeometry.titleSafe.maxY
            for s in sizes.reversed() {
                y -= s.height
                rects.insert(CGRect(x: MenuGeometry.titleSafe.minX, y: y, width: s.width, height: s.height), at: 0)
                y -= pitchGap
            }
            let listTop = y + pitchGap
            decor.append(PlannedDecor(role: .accentBar, rect: CGRect(x: MenuGeometry.titleSafe.minX, y: MenuGeometry.titleSafe.minY, width: 72, height: 8)))
            var cursor = MenuGeometry.titleSafe.minY + 8 + 40
            let maxTitleBottom = listTop - 40
            let subH: CGFloat = subtitleString.isEmpty ? 0 : 49 + 24
            if let title = titleBlock(width: 1060, height: max(120, min(430, maxTitleBottom - cursor - subH)), maxLines: 5, minSize: 56, align: .left) {
                texts.append(PlacedText(role: .title, block: title, x: MenuGeometry.titleSafe.minX, top: cursor, width: 1060, align: .left))
                cursor += title.height + 24
            }
            if let sub = subtitleBlock(width: 1060) {
                texts.append(PlacedText(role: .subtitle, block: sub, x: MenuGeometry.titleSafe.minX, top: cursor, width: 1060, align: .left))
            }
        }

        let buttons = zip(rects, items).map { rect, item in
            PlannedButton(rect: rect, content: .text(item.0), action: item.1)
        }
        return PlannedPage(kind: .main, buttons: buttons, neighbours: MenuNavigation.neighbours(for: rects),
                           texts: texts, decor: decor)
    }

    // MARK: Scene pages

    private static func scenesPage(index: Int, of pageCount: Int, chapters: [Double],
                                   settings: ScenePageSettings, style: MenuStyle,
                                   name: (Int) -> String) -> PlannedPage {
        let safe = MenuGeometry.titleSafe
        let perPage = settings.perPage
        let first = index * perPage
        let count = min(perPage, chapters.count - first)

        // Header row.
        var texts: [PlacedText] = []
        var decor: [PlannedDecor] = []
        let headerString = style.headerUppercase ? "SCENES" : "Scenes"
        let header = TypeBlock.line(headerString, font: style.headerFont, tracking: style.headerTracking)
        let headerAlign: TypeBlock.Align = style.mainLayout == .centredCard ? .center : .left
        texts.append(PlacedText(role: .header, block: header, x: safe.minX, top: safe.minY, width: safe.width, align: headerAlign))
        if pageCount > 1 {
            let ind = TypeBlock.line("\(index + 1) / \(pageCount)", font: style.labelFont, tracking: style.mainLayout == .centredCard ? 4 : 1)
            // Share the header's baseline.
            let top = safe.minY + header.ascent - ind.ascent
            texts.append(PlacedText(role: .indicator, block: ind, x: safe.minX, top: top, width: safe.width, align: .right))
        }
        var headerBottom = ceil(safe.minY + header.height)
        if style.mainLayout == .centredCard {
            decor.append(PlannedDecor(role: .hairline, rect: CGRect(x: safe.minX, y: headerBottom + 14, width: safe.width, height: 2)))
            headerBottom += 16
        }

        // Nav row along the bottom.
        let navLabels: [(String, MenuAction)] = {
            var l: [(String, MenuAction)] = [("Main menu", .goToPage(0))]
            if index > 0 { l.append(("Previous", .goToPage(index))) }
            if index < pageCount - 1 { l.append(("Next", .goToPage(index + 2))) }
            return l
        }()
        let navBlocks = navLabels.map { style.buttonBlock($0.0) }
        let navSizes = navBlocks.map { style.buttonSize(for: $0) }
        let navH = navSizes.map(\.height).max() ?? 0
        let navTop = safe.maxY - navH

        // Grid.
        let label = TypeBlock.line("Scene 88", font: style.labelFont)
        let labelH = ceil(label.ascent + label.descent)
        let ringMargin: CGFloat = 12
        let gridTop = ceil(headerBottom + 28)
        let gridBottom = navTop - 28
        let rowGap: CGFloat = 20
        let rows = settings.rows, cols = settings.columns
        let rowH = floor((gridBottom - gridTop - rowGap * CGFloat(rows - 1)) / CGFloat(rows))
        // cell = ring margin + thumb + 12 + label + 4
        var thumbH = rowH - ringMargin - 12 - labelH - 4
        let colGapMin: CGFloat = 40
        let widthBound = floor((safe.width - CGFloat(cols) * 2 * ringMargin - CGFloat(cols - 1) * colGapMin) / CGFloat(cols))
        var thumbW = floor(thumbH * 16 / 9)
        if thumbW > widthBound { thumbW = widthBound; thumbH = floor(thumbW * 9 / 16) }
        thumbW = floor(thumbW / 2) * 2
        thumbH = floor(thumbH / 2) * 2
        let cellW = thumbW + 2 * ringMargin
        let cellH = ringMargin + thumbH + 12 + labelH + 4
        let gap = min(120, floor((safe.width - CGFloat(cols) * cellW) / CGFloat(max(1, cols - 1))))
        let gridW = CGFloat(cols) * cellW + CGFloat(cols - 1) * gap
        let gridX = safe.minX + floor((safe.width - gridW) / 2)

        var buttons: [PlannedButton] = []
        for k in 0..<count {
            let chapter = first + k
            let r = k / cols, c = k % cols
            let rect = CGRect(x: gridX + CGFloat(c) * (cellW + gap), y: gridTop + CGFloat(r) * (cellH + rowGap),
                              width: cellW, height: cellH)
            let thumb = CGRect(x: rect.minX + ringMargin, y: rect.minY + ringMargin, width: thumbW, height: thumbH)
            buttons.append(PlannedButton(
                rect: rect,
                content: .scene(chapter: chapter, thumb: thumb, scene: name(chapter),
                                time: settings.showTimes ? timeString(chapters[chapter]) : nil),
                action: .playChapter(chapter)))
        }

        // Nav buttons: Main menu at the left, the rest at the right.
        var rightX = safe.maxX
        var navRects = [CGRect](repeating: .zero, count: navLabels.count)
        navRects[0] = CGRect(x: safe.minX, y: navTop, width: navSizes[0].width, height: navH)
        for k in stride(from: navLabels.count - 1, to: 0, by: -1) {
            rightX -= navSizes[k].width
            navRects[k] = CGRect(x: rightX, y: navTop, width: navSizes[k].width, height: navH)
            rightX -= 40
        }
        for (k, item) in navLabels.enumerated() {
            buttons.append(PlannedButton(rect: navRects[k], content: .text(item.0), action: item.1))
        }

        return PlannedPage(kind: .scenes(index: index, of: pageCount, firstChapter: first, count: count),
                           buttons: buttons, neighbours: MenuNavigation.neighbours(for: buttons.map(\.rect)),
                           texts: texts, decor: decor)
    }
}
