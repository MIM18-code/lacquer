import CoreGraphics
import Foundation

enum MenuRenderError: LocalizedError {
    case frameGrab(String)
    case imageUnreadable(String)
    case pageOutOfRange(Int)

    var errorDescription: String? {
        switch self {
        case .frameGrab(let why): return "Couldn't read a frame from the film. \(why)"
        case .imageUnreadable(let path): return "Couldn't open the background image \(path)."
        case .pageOutOfRange(let i): return "Menu has no page \(i)."
        }
    }
}

// MARK: - Frames from ffmpeg

/// Pulls single frames out of the film with ffmpeg, remembering recent ones
/// so editing text doesn't re-seek the film.
actor FrameStore {
    private let ffmpeg: URL
    private var cache: [String: CGImage] = [:]
    private var order: [String] = []
    private var bytes = 0
    private let byteLimit = 240_000_000

    init(ffmpeg: URL) { self.ffmpeg = ffmpeg }

    /// A frame scaled to fit within `box`, keeping the film's shape (pixel
    /// aspect applied).
    func frame(film: URL, at seconds: Double, fitting box: CGSize) async throws -> CGImage {
        let t = max(0, seconds)
        let key = "\(film.path)|\(Int((t * 1000).rounded()))|\(Int(box.width))x\(Int(box.height))"
        if let hit = cache[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return hit
        }
        let image = try await Self.grab(ffmpeg: ffmpeg, film: film, at: t, box: box)
        try Task.checkCancellation()
        cache[key] = image
        order.append(key)
        bytes += image.width * image.height * 4
        while bytes > byteLimit, let oldest = order.first, oldest != key {
            order.removeFirst()
            if let gone = cache.removeValue(forKey: oldest) { bytes -= gone.width * gone.height * 4 }
        }
        return image
    }

    /// Film length in seconds, read from `ffmpeg -i`'s banner.
    func duration(of film: URL) async -> Double? {
        let stderr: String
        do {
            let r = try await ProcessRunner.run(ffmpeg, arguments: ["-hide_banner", "-i", film.path])
            stderr = r.stderr
        } catch ProcessRunner.RunnerError.nonZeroExit(_, let err) {
            stderr = err   // ffmpeg exits 1 when given an input and no output
        } catch {
            return nil
        }
        guard let range = stderr.range(of: #"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)"#, options: .regularExpression) else { return nil }
        let parts = stderr[range].dropFirst("Duration: ".count).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    private static func grab(ffmpeg: URL, film: URL, at seconds: Double, box: CGSize) async throws -> CGImage {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("lacquer-menu-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }
        let filter = "scale=w=trunc(iw*sar/2)*2:h=ih,setsar=1,"
            + "scale=\(Int(box.width)):\(Int(box.height)):force_original_aspect_ratio=decrease:flags=lanczos"
        do {
            try await ProcessRunner.run(ffmpeg, arguments: [
                "-hide_banner", "-loglevel", "error", "-y",
                "-ss", String(format: "%.3f", seconds), "-i", film.path,
                "-an", "-sn", "-dn", "-frames:v", "1", "-vf", filter, out.path
            ])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MenuRenderError.frameGrab(error.localizedDescription)
        }
        guard let image = MenuImageIO.load(out, maxPixel: 4096) else {
            throw MenuRenderError.frameGrab("No frame at \(String(format: "%.1f", seconds)) s.")
        }
        return image
    }
}

// MARK: - Renderer

/// Turns a template, a film and its chapter times into a `DiscMenu`.
/// Hold on to one instance per film: it caches the frames it has pulled.
final class MenuRenderer: Sendable {
    let frames: FrameStore

    /// Chapter thumbnails are taken this long after the chapter starts, to
    /// skip the fade-in a cut often begins with.
    static let thumbnailOffset = 1.0
    static let thumbnailBox = CGSize(width: 640, height: 360)

    init(ffmpeg: URL) {
        frames = FrameStore(ffmpeg: ffmpeg)
    }

    func render(template: MenuTemplate, film: URL, chapters: [Double], hasSubtitles: Bool) async throws -> DiscMenu {
        let plan = MenuPlanner.plan(template: template, chapters: chapters, hasSubtitles: hasSubtitles)
        let still = try await backgroundStill(template, film: film)
        let thumbs = try await thumbnails(for: Array(plan.pages.indices), plan: plan, film: film, chapters: chapters)
        var pages: [MenuPage] = []
        for i in plan.pages.indices {
            try Task.checkCancellation()
            pages.append(Self.composePage(plan: plan, index: i, still: still, thumbnails: thumbs))
        }
        return DiscMenu(pages: pages)
    }

    /// One page, for live preview. Only the thumbnails that page shows are fetched.
    func renderPage(_ index: Int, template: MenuTemplate, film: URL, chapters: [Double], hasSubtitles: Bool) async throws -> MenuPage {
        let plan = MenuPlanner.plan(template: template, chapters: chapters, hasSubtitles: hasSubtitles)
        guard plan.pages.indices.contains(index) else { throw MenuRenderError.pageOutOfRange(index) }
        let still = try await backgroundStill(template, film: film)
        let thumbs = try await thumbnails(for: [index], plan: plan, film: film, chapters: chapters)
        try Task.checkCancellation()
        return Self.composePage(plan: plan, index: index, still: still, thumbnails: thumbs)
    }

    func duration(of film: URL) async -> Double? { await frames.duration(of: film) }

    /// A small frame for the designer's frame picker.
    func previewFrame(film: URL, at seconds: Double) async throws -> CGImage {
        try await frames.frame(film: film, at: seconds, fitting: CGSize(width: 480, height: 270))
    }

    // MARK: Fetching

    private func backgroundStill(_ template: MenuTemplate, film: URL) async throws -> CGImage {
        switch template.background {
        case .filmFrame(let seconds):
            return try await frames.frame(film: film, at: seconds, fitting: MenuGeometry.size)
        case .imageFile(let path):
            guard let image = MenuImageIO.load(URL(fileURLWithPath: path)) else {
                throw MenuRenderError.imageUnreadable(path)
            }
            return image
        }
    }

    private func thumbnails(for pageIndices: [Int], plan: MenuPlan, film: URL, chapters: [Double]) async throws -> [Int: CGImage] {
        var wanted: [Int] = []
        for p in pageIndices {
            for b in plan.pages[p].buttons {
                if case .scene(let chapter, _, _, _) = b.content { wanted.append(chapter) }
            }
        }
        var result: [Int: CGImage] = [:]
        let frames = self.frames
        try await withThrowingTaskGroup(of: (Int, CGImage?).self) { group in
            var next = 0
            func launch() {
                guard next < wanted.count else { return }
                let chapter = wanted[next]
                next += 1
                let time = chapters[chapter]
                group.addTask {
                    // A chapter at the very end can't give a frame a second in.
                    for t in [time + Self.thumbnailOffset, time] {
                        if let img = try? await frames.frame(film: film, at: t, fitting: Self.thumbnailBox) {
                            return (chapter, img)
                        }
                        try Task.checkCancellation()
                    }
                    return (chapter, nil)
                }
            }
            for _ in 0..<min(4, wanted.count) { launch() }
            while let (chapter, image) = try await group.next() {
                if let image { result[chapter] = image }
                launch()
            }
        }
        return result
    }

    // MARK: Composing (pure: no ffmpeg, no file access)

    /// Builds a complete menu from stills you already have.
    static func compose(template: MenuTemplate, chapters: [Double], hasSubtitles: Bool,
                        still: CGImage, thumbnails: [Int: CGImage]) -> DiscMenu {
        let plan = MenuPlanner.plan(template: template, chapters: chapters, hasSubtitles: hasSubtitles)
        return DiscMenu(pages: plan.pages.indices.map {
            composePage(plan: plan, index: $0, still: still, thumbnails: thumbnails)
        })
    }

    static func composePage(plan: MenuPlan, index: Int, still: CGImage, thumbnails: [Int: CGImage]) -> MenuPage {
        let page = plan.pages[index]
        let style = plan.style
        let background = MenuArt.background(page: page, style: style, still: still, thumbnails: thumbnails)

        var images: [CGImage] = []
        for b in page.buttons {
            for state in MenuArt.ButtonState.allCases {
                images.append(MenuArt.button(b, style: style, state: state))
            }
        }
        let reduced = MenuPalette.reduce(images)
        var buttons: [MenuButton] = []
        for (i, b) in page.buttons.enumerated() {
            let n = page.neighbours[i]
            buttons.append(MenuButton(
                id: i, rect: b.rect,
                normal: reduced[i * 3], selected: reduced[i * 3 + 1], activated: reduced[i * 3 + 2],
                up: n.up, down: n.down, left: n.left, right: n.right, action: b.action))
        }
        return MenuPage(background: background, buttons: buttons, defaultButton: page.defaultButton)
    }
}

// MARK: - Art

/// The pixels: per-preset backgrounds and the three states of each button.
enum MenuArt {
    enum ButtonState: CaseIterable { case normal, selected, activated }

    // MARK: Backgrounds

    static func background(page: PlannedPage, style: MenuStyle, still: CGImage, thumbnails: [Int: CGImage]) -> CGImage {
        let c = MenuCanvas(width: 1920, height: 1080, opaque: true)
        let frame = MenuGeometry.frame
        let isMain = page.kind == .main

        switch style.preset {
        case .fullFrame:
            if isMain {
                c.draw(still, in: frame, fit: .fill)
                c.fill(frame, MenuColor.black.with(alpha: 0.1))
                c.linearGradient(in: frame, from: CGPoint(x: 0, y: 1080), to: CGPoint(x: 0, y: 440),
                                 stops: [(0, .black.with(alpha: 0.9)), (0.5, .black.with(alpha: 0.45)), (1, .clear)])
                c.linearGradient(in: frame, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 1300, y: 0),
                                 stops: [(0, .black.with(alpha: 0.55)), (1, .clear)])
            } else {
                c.draw(MenuImageOps.blurred(still, width: 1920, height: 1080, sigma: 36), in: frame, fit: .fill)
                c.fill(frame, MenuColor.black.with(alpha: 0.72))
                c.radialGradient(center: CGPoint(x: 960, y: 540), radius: 1400, scaleY: 0.7,
                                 stops: [(0.4, .clear), (1, .black.with(alpha: 0.6))], clip: frame)
            }

        case .titleCard:
            c.fill(frame, style.ground)
            if isMain {
                let band = CGRect(x: 0, y: 84, width: 1920, height: 803)
                c.draw(still, in: band, fit: .fill)
                c.fill(band, MenuColor.black.with(alpha: 0.3))
                c.radialGradient(center: CGPoint(x: 960, y: 485), radius: 900, scaleY: 0.5,
                                 stops: [(0, .black.with(alpha: 0.55)), (1, .clear)], clip: band)
            }

        case .typographic:
            c.fill(frame, style.ground)
            let panel = CGRect(x: 700, y: 0, width: 1220, height: 1080)
            c.fill(panel, MenuColor(hex: 0x5A4A3F))
            c.draw(still, in: panel, fit: .fill, blend: .luminosity)
            c.fill(panel, MenuColor.black.with(alpha: isMain ? 0.35 : 0.72))
            c.linearGradient(in: panel, from: CGPoint(x: 700, y: 0), to: CGPoint(x: 1320, y: 0),
                             stops: [(0, style.ground), (1, style.ground.with(alpha: 0))])
        }

        for d in page.decor {
            switch d.role {
            case .accentBar: c.fill(d.rect, style.accent)
            case .hairline: c.fill(d.rect, style.text.with(alpha: 0.25))
            }
        }
        for t in page.texts {
            let color: MenuColor
            switch t.role {
            case .title, .header: color = style.text
            case .subtitle: color = style.subtitleColor
            case .indicator: color = style.text.with(alpha: 0.6)
            }
            c.draw(t.block, atX: t.x, top: t.top, align: t.align, width: t.width, color: color)
        }

        // Scene thumbnails live in the background so they keep full colour.
        for b in page.buttons {
            guard case .scene(let chapter, let thumb, _, _) = b.content else { continue }
            c.fillRounded(thumb, radius: 4, MenuColor(hex: 0x15151A))
            if let img = thumbnails[chapter] {
                c.draw(img, in: thumb, fit: .fit, cornerRadius: 4)
            }
        }
        return c.makeImage()
    }

    // MARK: Buttons

    static func button(_ b: PlannedButton, style: MenuStyle, state: ButtonState) -> CGImage {
        let size = b.rect.size
        let c = MenuCanvas(width: Int(size.width), height: Int(size.height), opaque: false)
        switch b.content {
        case .text(let label): drawTextButton(c, label: label, size: size, style: style, state: state)
        case .scene(_, let thumb, let scene, let time):
            drawSceneButton(c, thumb: thumb.offsetBy(dx: -b.rect.minX, dy: -b.rect.minY),
                            scene: scene, time: time, style: style, state: state)
        }
        return c.makeImage()
    }

    private static func textColor(_ style: MenuStyle, _ state: ButtonState) -> MenuColor {
        switch state {
        case .normal: return style.text.with(alpha: style.dimAlpha)
        case .selected: return style.text
        case .activated: return style.accent
        }
    }

    private static func drawTextButton(_ c: MenuCanvas, label: String, size: CGSize, style: MenuStyle, state: ButtonState) {
        let block = style.buttonBlock(label)
        let origin = style.textOrigin(for: block, in: size)
        let w = size.width, h = size.height
        switch style.selection {
        case .underline:
            if state != .normal {
                let color = state == .selected ? style.accent : style.text
                c.fill(CGRect(x: 0, y: h - MenuStyle.underlineThickness, width: w, height: MenuStyle.underlineThickness), color)
            }
        case .capsule:
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            switch state {
            case .normal: break
            case .selected:
                c.fillRounded(rect, radius: h / 2, style.text.with(alpha: 0.2))
                c.strokeRounded(rect, radius: h / 2, width: 4, style.text)
            case .activated:
                c.fillRounded(rect, radius: h / 2, style.accent.with(alpha: 0.4))
                c.strokeRounded(rect, radius: h / 2, width: 6, style.accent)
            }
        case .marker:
            if state != .normal {
                let side: CGFloat = state == .activated ? 30 : 24
                let cy = origin.y + block.ascent - block.capHeight / 2
                c.fill(CGRect(x: 0, y: (cy - side / 2).rounded(), width: side, height: side), style.accent)
            }
        }
        c.draw(block, atX: origin.x, top: origin.y, color: textColor(style, state))
    }

    private static func drawSceneButton(_ c: MenuCanvas, thumb: CGRect, scene: String, time: String?,
                                        style: MenuStyle, state: ButtonState) {
        switch state {
        case .normal:
            c.fillRounded(thumb, radius: 4, MenuColor.black.with(alpha: 0.6))
        case .selected:
            c.ring(around: thumb, gap: 4, width: 6, radius: 4, style.accent)
        case .activated:
            c.fillRounded(thumb, radius: 4, style.accent.with(alpha: 0.27))
            c.ring(around: thumb, gap: 4, width: 6, radius: 4, style.text)
        }

        let sceneColor: MenuColor, timeColor: MenuColor
        switch state {
        case .normal: sceneColor = style.text.with(alpha: style.dimAlpha); timeColor = style.text.with(alpha: 0.4)
        case .selected: sceneColor = style.text; timeColor = style.text.with(alpha: 0.8)
        case .activated: sceneColor = style.accent; timeColor = style.accent
        }
        var sceneBlock = TypeBlock.line(scene, font: style.labelFont, tracking: style.preset == .titleCard ? 2 : 0)
        var timeBlock = time.map { TypeBlock.line($0, font: style.labelFont, tracking: style.preset == .titleCard ? 2 : 0) }
        let gap: CGFloat = 22
        let total = sceneBlock.width + (timeBlock.map { gap + $0.width } ?? 0)
        if total > thumb.width {
            // Rare: a long time on a narrow tile. Shrink both together.
            let size = max(32, style.labelFont.size * thumb.width / total)
            sceneBlock = TypeBlock.line(scene, font: style.labelFont.sized(size))
            timeBlock = time.map { TypeBlock.line($0, font: style.labelFont.sized(size)) }
        }
        let top = thumb.maxY + 12
        c.draw(sceneBlock, atX: thumb.minX, top: top, color: sceneColor)
        if let timeBlock {
            c.draw(timeBlock, atX: thumb.minX + sceneBlock.width + gap, top: top, color: timeColor)
        }
    }
}
