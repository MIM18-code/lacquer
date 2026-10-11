#if DEBUG
import Foundation

/// Debug-only command line hooks for looking at menus without wiring them
/// into the app:
///
///     Lacquer --menu-render FILM OUTDIR [--chapters N] [--title T] [--subtitle S] [--at SECONDS] [--guides]
///     Lacquer --menu-designer FILM [--chapters N] [--no-srt]
enum MenuDebug {
    static func isMenuCommand(_ args: [String]) -> Bool {
        args.contains("--menu-render") || args.contains("--menu-designer")
    }

    /// Runs the requested menu command. `--menu-render` exits when done;
    /// `--menu-designer` opens a window.
    static func run(_ args: [String]) {
        if args.contains("--menu-render") {
            Task {
                let code = await render(args)
                exit(code)
            }
            dispatchMain()
        } else {
            MenuDesignerDebugApp.main()
        }
    }

    static func option(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Finds ffmpeg the way the app does, plus the vendored build in this repo.
    static func ffmpegURL() -> URL? {
        if let tools = try? ToolLocator.locate() { return tools.ffmpeg }
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Evenly spaced chapters, the way a custom list would be.
    static func chapters(count: Int, duration: Double) -> [Double] {
        guard count > 0 else { return [] }
        return (0..<count).map { (duration * Double($0) / Double(count)).rounded(.down) }
    }

    static func render(_ args: [String]) async -> Int32 {
        guard let i = args.firstIndex(of: "--menu-render"), i + 2 < args.count else {
            print("usage: --menu-render FILM OUTDIR [--chapters N] [--title T] [--subtitle S] [--at SECONDS] [--guides]")
            return 2
        }
        let film = URL(fileURLWithPath: args[i + 1])
        let out = URL(fileURLWithPath: args[i + 2])
        guard let ffmpeg = ffmpegURL() else { print("no ffmpeg"); return 1 }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let renderer = MenuRenderer(ffmpeg: ffmpeg)
        let duration = await renderer.duration(of: film) ?? 600
        let n = Int(option("--chapters", in: args) ?? "") ?? 8
        let chapters = chapters(count: n, duration: duration)
        let guides = args.contains("--guides")

        for preset in MenuStylePreset.allCases {
            var t = MenuTemplate.suggested(forFilm: film, duration: duration)
            t.title = option("--title", in: args) ?? "The Long Goodbye"
            t.subtitle = option("--subtitle", in: args) ?? "2026  ·  A film by Joshua Land"
            t.style = preset
            if let at = option("--at", in: args).flatMap(Double.init) { t.background = .filmFrame(seconds: at) }
            let started = Date()
            do {
                let menu = try await renderer.render(template: t, film: film, chapters: chapters, hasSubtitles: true)
                for (p, page) in menu.pages.enumerated() {
                    let base = "\(preset.rawValue)_p\(p)"
                    try MenuImageIO.writePNG(page.background, to: out.appendingPathComponent("\(base)_background.png"))
                    for k in page.buttons.indices {
                        try MenuImageIO.writePNG(MenuPreview.composite(page, highlight: .selected(k), showSafeAreas: guides),
                                                 to: out.appendingPathComponent("\(base)_sel\(k).png"))
                    }
                    try MenuImageIO.writePNG(MenuPreview.composite(page, highlight: .activated(0), showSafeAreas: false),
                                             to: out.appendingPathComponent("\(base)_activated0.png"))
                    print("\(preset.rawValue) page \(p): \(page.buttons.count) buttons, \(MenuPalette.colorCount(of: page)) palette entries")
                }
                print(String(format: "%@ rendered in %.2fs", preset.rawValue, Date().timeIntervalSince(started)))
            } catch {
                print("\(preset.rawValue) failed: \(error.localizedDescription)")
                return 1
            }
        }
        return 0
    }
}
#endif
