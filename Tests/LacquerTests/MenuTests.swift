import XCTest
import CoreGraphics
@testable import Lacquer

final class MenuTests: XCTestCase {

    // MARK: Fixtures

    private func chapters(_ n: Int) -> [Double] { (0..<n).map { Double($0) * 90 } }

    private func template(_ style: MenuStylePreset, title: String = "The Long Goodbye",
                          subtitle: String = "2026  ·  A film by Someone") -> MenuTemplate {
        var t = MenuTemplate()
        t.title = title
        t.subtitle = subtitle
        t.style = style
        return t
    }

    /// A colourful frame so the art has something to sit on.
    private func still(width: Int = 1920, height: Int = 1080) -> CGImage {
        let c = MenuCanvas(width: width, height: height, opaque: true)
        c.linearGradient(in: c.bounds, from: .zero, to: CGPoint(x: CGFloat(width), y: CGFloat(height)),
                         stops: [(0, MenuColor(0.9, 0.55, 0.2)), (0.5, MenuColor(0.2, 0.5, 0.6)), (1, MenuColor(0.1, 0.1, 0.3))])
        return c.makeImage()
    }

    private func menu(_ style: MenuStylePreset, chapters n: Int, subtitles: Bool = true,
                      title: String = "The Long Goodbye") -> DiscMenu {
        let thumb = still(width: 640, height: 360)
        var thumbs: [Int: CGImage] = [:]
        for i in 0..<n { thumbs[i] = thumb }
        return MenuRenderer.compose(template: template(style, title: title), chapters: chapters(n),
                                    hasSubtitles: subtitles, still: still(), thumbnails: thumbs)
    }

    private func plan(_ style: MenuStylePreset, chapters n: Int, subtitles: Bool = true,
                      title: String = "The Long Goodbye", settings: ScenePageSettings = ScenePageSettings()) -> MenuPlan {
        var t = template(style, title: title)
        t.scenePages = settings
        return MenuPlanner.plan(template: t, chapters: chapters(n), hasSubtitles: subtitles)
    }

    // MARK: Output sizes and geometry

    func testRendererOutputSizes() {
        for style in MenuStylePreset.allCases {
            let m = menu(style, chapters: 8)
            XCTAssertEqual(m.pages.count, 3, "\(style)")   // main + 2 scene pages
            for page in m.pages {
                XCTAssertEqual(page.background.width, 1920)
                XCTAssertEqual(page.background.height, 1080)
                let alpha = page.background.alphaInfo
                XCTAssertTrue(alpha == .noneSkipLast || alpha == .noneSkipFirst || alpha == .none,
                              "background must be opaque, got \(alpha)")
            }
        }
    }

    func testStateImagesAreExactlyRectSized() {
        for style in MenuStylePreset.allCases {
            for page in menu(style, chapters: 8).pages {
                for b in page.buttons {
                    XCTAssertEqual(b.rect, b.rect.integral, "\(style) button \(b.id) rect not whole pixels")
                    for img in [b.normal, b.selected, b.activated] {
                        XCTAssertEqual(CGFloat(img.width), b.rect.width, "\(style) button \(b.id)")
                        XCTAssertEqual(CGFloat(img.height), b.rect.height, "\(style) button \(b.id)")
                    }
                }
            }
        }
    }

    func testEveryButtonAndTextIsInsideTitleSafe() {
        let safe = MenuGeometry.titleSafe
        let longTitle = String(repeating: "Extraordinarily Long Film Title ", count: 6)
        for style in MenuStylePreset.allCases {
            for n in [1, 2, 6, 13, 40] {
                for title in ["The Long Goodbye", longTitle, ""] {
                    let p = plan(style, chapters: n, title: title)
                    for page in p.pages {
                        for b in page.buttons {
                            XCTAssertTrue(safe.contains(b.rect), "\(style) n=\(n) button \(b.rect) outside title-safe")
                            XCTAssertTrue(MenuGeometry.frame.contains(b.rect))
                            if case .scene(_, let thumb, _, _) = b.content {
                                XCTAssertTrue(b.rect.contains(thumb))
                            }
                        }
                        for t in page.texts {
                            XCTAssertTrue(safe.insetBy(dx: -0.5, dy: -0.5).contains(t.bounds),
                                          "\(style) \(t.role) \(t.bounds) outside title-safe")
                        }
                        for d in page.decor {
                            XCTAssertTrue(safe.contains(d.rect), "\(style) decor \(d.rect)")
                        }
                    }
                }
            }
        }
    }

    func testTextIsLargeEnoughForATV() {
        for style in MenuStylePreset.allCases {
            let s = MenuStyle.style(for: style)
            XCTAssertGreaterThanOrEqual(s.buttonFont.size, 40)
            XCTAssertGreaterThanOrEqual(s.labelFont.size, 40)
            XCTAssertGreaterThanOrEqual(s.subtitleFont.size, 40)
            for page in plan(style, chapters: 8).pages {
                for b in page.buttons {
                    XCTAssertGreaterThanOrEqual(b.rect.height, 40)
                }
            }
        }
    }

    func testButtonsDoNotOverlapAndTextDoesNotHitButtons() {
        for style in MenuStylePreset.allCases {
            for page in plan(style, chapters: 13).pages {
                for (i, a) in page.buttons.enumerated() {
                    for b in page.buttons[(i + 1)...] {
                        XCTAssertFalse(a.rect.intersects(b.rect), "\(style) \(a.rect) overlaps \(b.rect)")
                    }
                    for t in page.texts {
                        XCTAssertFalse(a.rect.intersects(t.bounds), "\(style) button \(a.rect) hits \(t.role) \(t.bounds)")
                    }
                }
            }
        }
    }

    // MARK: Buttons offered

    func testMainPageButtonsFollowWhatTheFilmAllows() {
        func labels(_ p: MenuPlan) -> [String] {
            p.pages[0].buttons.compactMap { if case .text(let s) = $0.content { return s } else { return nil } }
        }
        XCTAssertEqual(labels(plan(.fullFrame, chapters: 1, subtitles: false)), ["Play"])
        XCTAssertEqual(labels(plan(.fullFrame, chapters: 0, subtitles: false)), ["Play"])
        XCTAssertEqual(labels(plan(.fullFrame, chapters: 2, subtitles: false)), ["Play", "Scenes"])
        XCTAssertEqual(labels(plan(.fullFrame, chapters: 1, subtitles: true)), ["Play", "Subtitles On", "Subtitles Off"])
        XCTAssertEqual(labels(plan(.fullFrame, chapters: 5, subtitles: true)),
                       ["Play", "Scenes", "Subtitles On", "Subtitles Off"])

        var t = template(.titleCard)
        t.includeScenes = false
        t.includeSubtitles = false
        let p = MenuPlanner.plan(template: t, chapters: chapters(10), hasSubtitles: true)
        XCTAssertEqual(labels(p), ["Play"])
        XCTAssertEqual(p.pages.count, 1)

        let actions = plan(.fullFrame, chapters: 5).pages[0].buttons.map(\.action)
        XCTAssertEqual(actions, [.playFilm, .goToPage(1), .setSubtitles(on: true), .setSubtitles(on: false)])
    }

    // MARK: Paging

    func testScenePaging() {
        // Default grid is 3 × 2 = 6 per page.
        let expected: [(chapters: Int, scenePages: Int)] = [(1, 0), (6, 1), (13, 3), (40, 7)]
        for style in MenuStylePreset.allCases {
            for (n, scenePages) in expected {
                let p = plan(style, chapters: n)
                XCTAssertEqual(p.scenePageCount, scenePages, "\(style) \(n) chapters")
                XCTAssertEqual(p.pages.count, scenePages + 1)

                // Every chapter appears exactly once, in order, on the right page.
                var seen: [Int] = []
                for (i, page) in p.pages.enumerated().dropFirst() {
                    guard case .scenes(let index, let of, let first, let count) = page.kind else {
                        return XCTFail("expected scene page")
                    }
                    XCTAssertEqual(index, i - 1)
                    XCTAssertEqual(of, scenePages)
                    XCTAssertEqual(first, (i - 1) * 6)
                    let tiles = page.buttons.compactMap { b -> Int? in
                        if case .scene(let c, _, _, _) = b.content { return c } else { return nil }
                    }
                    XCTAssertEqual(tiles.count, count)
                    seen += tiles

                    let labels = page.buttons.compactMap { b -> String? in
                        if case .text(let s) = b.content { return s } else { return nil }
                    }
                    XCTAssertEqual(labels.first, "Main menu")
                    XCTAssertEqual(labels.contains("Previous"), i > 1)
                    XCTAssertEqual(labels.contains("Next"), i < scenePages)
                    for b in page.buttons {
                        if case .goToPage(let target) = b.action {
                            XCTAssertTrue(p.pages.indices.contains(target), "dangling goToPage(\(target))")
                        }
                    }
                }
                XCTAssertEqual(seen, scenePages == 0 ? [] : Array(0..<n))
            }
        }
    }

    func testSceneGridSettings() {
        var s = ScenePageSettings()
        s.columns = 2; s.rows = 1
        XCTAssertEqual(plan(.fullFrame, chapters: 7, settings: s).scenePageCount, 4)
        s.columns = 9; s.rows = 9   // out of range values are clamped
        XCTAssertEqual(s.perPage, 6)
        // Wrong-way and small grids still fit the safe area.
        for cols in 2...3 {
            for rows in 1...2 {
                var g = ScenePageSettings(); g.columns = cols; g.rows = rows
                for style in MenuStylePreset.allCases {
                    for page in plan(style, chapters: 9, settings: g).pages {
                        for b in page.buttons { XCTAssertTrue(MenuGeometry.titleSafe.contains(b.rect)) }
                    }
                }
            }
        }
    }

    func testSceneLabels() {
        let p = plan(.fullFrame, chapters: 3)
        guard case .scene(_, _, let scene, let time) = p.pages[1].buttons[1].content else { return XCTFail() }
        XCTAssertEqual(scene, "Scene 2")
        XCTAssertEqual(time, "1:30")
        XCTAssertEqual(MenuPlanner.timeString(0), "0:00")
        XCTAssertEqual(MenuPlanner.timeString(754), "12:34")
        XCTAssertEqual(MenuPlanner.timeString(3723), "1:02:03")
    }

    // MARK: Remote navigation

    func testNavigationHasNoDeadEndsAndReachesEverything() {
        for style in MenuStylePreset.allCases {
            for n in [1, 2, 6, 13, 40] {
                for page in plan(style, chapters: n).pages {
                    let nav = page.neighbours
                    let count = nav.count
                    func moves(_ i: Int) -> [Int] { [nav[i].up, nav[i].down, nav[i].left, nav[i].right].compactMap { $0 } }
                    for i in 0..<count {
                        for target in moves(i) {
                            XCTAssertTrue(nav.indices.contains(target))
                            XCTAssertNotEqual(target, i, "button points at itself")
                        }
                        if count > 1 { XCTAssertFalse(moves(i).isEmpty, "\(style) n=\(n): button \(i) is a dead end") }
                    }
                    // You can get from any button to any other.
                    for start in 0..<count {
                        var reached: Set<Int> = [start]
                        var queue = [start]
                        while let i = queue.popLast() {
                            for t in moves(i) where reached.insert(t).inserted { queue.append(t) }
                        }
                        XCTAssertEqual(reached.count, count, "\(style) n=\(n): can't reach everything from button \(start)")
                    }
                }
            }
        }
    }

    func testRenderedButtonsCarryThePlannedNavigation() {
        for style in MenuStylePreset.allCases {
            let p = plan(style, chapters: 8)
            let m = menu(style, chapters: 8)
            for (page, planned) in zip(m.pages, p.pages) {
                XCTAssertEqual(page.buttons.map { MenuNeighbours(up: $0.up, down: $0.down, left: $0.left, right: $0.right) },
                               planned.neighbours)
                XCTAssertEqual(page.buttons.map(\.rect), planned.buttons.map(\.rect))
                XCTAssertEqual(page.buttons.map(\.action), planned.buttons.map(\.action))
            }
        }
    }

    func testNavigationIsSymmetricWhereItShouldBe() {
        for style in MenuStylePreset.allCases {
            for n in [6, 13, 40] {
                for page in plan(style, chapters: n).pages {
                    let nav = page.neighbours
                    for (i, node) in nav.enumerated() {
                        if let r = node.right { XCTAssertEqual(nav[r].left, i, "\(style) right/left asymmetry at \(i)") }
                        if let l = node.left { XCTAssertEqual(nav[l].right, i, "\(style) left/right asymmetry at \(i)") }
                    }
                    // Within the tile grid, up and down also mirror each other.
                    let tiles = page.buttons.indices.filter {
                        if case .scene = page.buttons[$0].content { return true } else { return false }
                    }
                    // (A short last row has fewer columns, so Down from the far column
                    // lands on the nearest tile and Up can't mirror it: only full pages.)
                    guard tiles.count == 6 else { continue }
                    for i in tiles {
                        if let d = nav[i].down, tiles.contains(d) { XCTAssertEqual(nav[d].up, i, "\(style) down/up asymmetry at \(i)") }
                        if let u = nav[i].up, tiles.contains(u) { XCTAssertEqual(nav[u].down, i, "\(style) up/down asymmetry at \(i)") }
                    }
                }
            }
        }
    }

    func testNavigationMovesTheWayTheEyeExpects() {
        // 3 × 2 grid on the first of three pages.
        let page = plan(.fullFrame, chapters: 13).pages[1]
        let nav = page.neighbours
        XCTAssertEqual(nav[0].right, 1)
        XCTAssertEqual(nav[1].right, 2)
        XCTAssertNil(nav[2].right)
        XCTAssertEqual(nav[0].down, 3)
        XCTAssertEqual(nav[3].up, 0)
        XCTAssertNil(nav[0].up)
        XCTAssertNil(nav[0].left)
        // Row 2 leads down to the nav row: Main menu under the left column.
        XCTAssertEqual(page.buttons[nav[3].down!].action, .goToPage(0))
        // Main menu then Next along the bottom.
        let mainMenu = 6, next = 7
        XCTAssertEqual(nav[mainMenu].right, next)
        XCTAssertEqual(nav[next].left, mainMenu)
    }

    func testMainPageNavigationMatchesLayout() {
        let row = plan(.fullFrame, chapters: 5).pages[0].neighbours
        XCTAssertEqual(row.map(\.right), [1, 2, 3, nil])
        XCTAssertEqual(row.map(\.left), [nil, 0, 1, 2])
        XCTAssertTrue(row.allSatisfy { $0.up == nil && $0.down == nil })

        let column = plan(.typographic, chapters: 5).pages[0].neighbours
        XCTAssertEqual(column.map(\.down), [1, 2, 3, nil])
        XCTAssertEqual(column.map(\.up), [nil, 0, 1, 2])
    }

    // MARK: Palette

    func testEveryPresetPageStaysUnderTheHDMVPaletteLimit() {
        for style in MenuStylePreset.allCases {
            let m = menu(style, chapters: 13)
            for i in m.pages.indices {
                let count = MenuPalette.colorCount(of: m, page: i)
                XCTAssertLessThanOrEqual(count, MenuPalette.maxEntries, "\(style) page \(i) uses \(count) colours")
                XCTAssertGreaterThan(count, 3, "\(style) page \(i) looks empty")
            }
        }
    }

    func testQuantizerEnforcesTheLimitOnHostileArt() {
        // Smooth gradients with alpha: thousands of distinct colours.
        let c = MenuCanvas(width: 300, height: 200, opaque: false)
        for i in 0..<5 {
            let hue = Double(i) / 5
            c.linearGradient(in: CGRect(x: 0, y: CGFloat(i) * 40, width: 300, height: 40), from: .zero,
                             to: CGPoint(x: 300, y: 0),
                             stops: [(0, MenuColor(hue, 0.2, 1 - hue, 0.1)), (1, MenuColor(1 - hue, hue, 0.5, 1))])
        }
        let raw = c.makeImage()
        XCTAssertGreaterThan(MenuPalette.colorCount(of: [raw]), 1000)
        let reduced = MenuPalette.reduce([raw])
        XCTAssertLessThanOrEqual(MenuPalette.colorCount(of: reduced), MenuPalette.maxEntries)
        XCTAssertEqual(reduced[0].width, 300)
        XCTAssertEqual(reduced[0].height, 200)
    }

    func testQuantizerKeepsFlatColoursFlat() {
        let c = MenuCanvas(width: 100, height: 60, opaque: false)
        c.fillRounded(CGRect(x: 10, y: 10, width: 80, height: 40), radius: 20, MenuColor(0.9, 0.7, 0.3))
        let reduced = MenuPalette.reduce([c.makeImage()])[0]
        let bytes = MenuImageIO.straightRGBA(reduced)
        // Pixel in the middle of the shape keeps its colour and full alpha.
        let i = (30 * 100 + 50) * 4
        XCTAssertEqual(Int(bytes[i]), 230, accuracy: 2)
        XCTAssertEqual(Int(bytes[i + 1]), 179, accuracy: 2)
        XCTAssertEqual(Int(bytes[i + 2]), 77, accuracy: 2)
        XCTAssertEqual(bytes[i + 3], 255)
        // Corner stays clear.
        XCTAssertEqual(bytes[3], 0)
    }

    // MARK: Selection must be visible

    func testSelectedStateDiffersFromNormal() {
        for style in MenuStylePreset.allCases {
            for page in menu(style, chapters: 8).pages {
                for b in page.buttons {
                    let n = MenuImageIO.straightRGBA(b.normal)
                    let s = MenuImageIO.straightRGBA(b.selected)
                    let a = MenuImageIO.straightRGBA(b.activated)
                    XCTAssertNotEqual(n, s, "\(style) button \(b.id): selected looks like normal")
                    XCTAssertNotEqual(s, a, "\(style) button \(b.id): activated looks like selected")
                }
            }
        }
    }

    // MARK: Template

    func testTemplateRoundTripsThroughJSON() throws {
        var t = template(.typographic)
        t.background = .imageFile(path: "/tmp/poster.png")
        t.scenePages.columns = 2
        t.includeSubtitles = false
        let back = try JSONDecoder().decode(MenuTemplate.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back, t)

        var u = t
        u.background = .filmFrame(seconds: 12.5)
        XCTAssertEqual(try JSONDecoder().decode(MenuTemplate.self, from: JSONEncoder().encode(u)), u)
    }

    // MARK: ffmpeg end to end

    func testRenderFromARealFilm() async throws {
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            ?? ProcessInfo.processInfo.environment["DISC_TOOLS_DIR"].map({ $0 + "/ffmpeg" })
            .flatMap({ FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil })
        else { throw XCTSkip("no ffmpeg available") }
        let ffmpegURL = URL(fileURLWithPath: ffmpeg)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lacquer-menu-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let film = dir.appendingPathComponent("film.mp4")
        try await ProcessRunner.run(ffmpegURL, arguments: [
            "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24:duration=20",
            "-pix_fmt", "yuv420p", "-c:v", "libx264", "-preset", "ultrafast", film.path
        ])

        let renderer = MenuRenderer(ffmpeg: ffmpegURL)
        let duration = await renderer.duration(of: film)
        XCTAssertEqual(try XCTUnwrap(duration), 20, accuracy: 0.5)

        var t = template(.fullFrame)
        t.background = .filmFrame(seconds: 5)
        let times: [Double] = [0, 4, 8, 12, 16, 19.9, 25]   // the last is past the end
        let menu = try await renderer.render(template: t, film: film, chapters: times, hasSubtitles: true)
        XCTAssertEqual(menu.pages.count, 3)
        XCTAssertEqual(menu.pages[0].background.width, 1920)
        XCTAssertEqual(menu.pages[1].buttons.count, 8)   // 6 tiles, Main menu, Next
        XCTAssertLessThanOrEqual(MenuPalette.colorCount(of: menu, page: 1), MenuPalette.maxEntries)

        // A single page on its own matches the full render's shape.
        let page = try await renderer.renderPage(1, template: t, film: film, chapters: times, hasSubtitles: true)
        XCTAssertEqual(page.buttons.count, menu.pages[1].buttons.count)

        // A bad image path is a clear error, not a crash.
        t.background = .imageFile(path: dir.appendingPathComponent("missing.png").path)
        do {
            _ = try await renderer.renderPage(0, template: t, film: film, chapters: times, hasSubtitles: false)
            XCTFail("expected an error")
        } catch let error as MenuRenderError {
            XCTAssertNotNil(error.errorDescription)
        }
    }
}
