import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Adds HDMV menus to a BDMV folder tsMuxeR has already written with the
/// film as playlist 00000. tsMuxeR keeps the film's clip, chapters, audio
/// and subtitles exactly as before; this adds one menu clip and playlist per
/// page and replaces index.bdmv and MovieObject.bdmv so the disc opens on
/// the menu and Top Menu returns to it.
///
/// Disc layout:
/// - Movie object 0 is the film (title 1). It plays 00000.mpls from the
///   chapter mark in GPR0 (0 = the start), with subtitles shown if GPR2 is 1,
///   and goes back to the first menu page when the film ends.
/// - Movie object 1 + p selects page p's default button, then plays its
///   playlist (01000 + p) in a loop. The page's IG composition names no
///   default button, so the player uses that stored selection, and a loop
///   restart keeps whatever the viewer had selected.
/// - First Playback and Top Menu both run the first page's object.
/// - Buttons set GPR0/GPR2 and jump to title 1, or jump to another page's
///   object. Button commands can't change playlists themselves.
struct HDMVMenuAuthor {
    let ffmpeg: URL

    static let filmPlaylist = 0
    static let chapterRegister = 0
    static let subtitleRegister = 2
    /// 1080p23.976: every BD player supports it, whatever the film's format.
    static let menuFrameRate = M2TSMuxer.FrameRate(numerator: 24000, denominator: 1001)
    static let menuLanguage = "eng"

    static func menuPlaylist(page: Int) -> Int { 1000 + page }
    static func menuObject(page: Int) -> Int { 1 + page }
    static func clipName(_ number: Int) -> String { String(format: "%05d", number) }

    enum MenuError: LocalizedError {
        case invalid(String)
        case missingFilm(URL)

        var errorDescription: String? {
            switch self {
            case .invalid(let m): return "The disc menu can't be authored: \(m)."
            case .missingFilm(let url): return "No film playlist at \(url.path) to add menus to."
            }
        }
    }

    // MARK: - Navigation (pure)

    struct Navigation: Equatable {
        var objects: [MovieObject]
        var index: IndexTable
        /// [page][button]
        var buttonCommands: [[[NavCommand]]]
        /// [page][button] → up, down, left, right as button ids.
        var neighbours: [[[Int]]]
    }

    static func navigation(for menu: DiscMenu, film: PlaylistSummary) throws -> Navigation {
        guard !menu.pages.isEmpty else { throw MenuError.invalid("it has no pages") }
        guard menu.pages.count <= 1000 else { throw MenuError.invalid("it has more than 1000 pages") }
        guard menu.pages.indices.contains(menu.firstPage) else {
            throw MenuError.invalid("first page \(menu.firstPage + 1) doesn't exist")
        }
        let first = menuObject(page: menu.firstPage)

        var film0: [NavCommand] = []
        if film.subtitleStreams > 0 {
            film0 += [.setSubtitleStream(1, displayed: false),
                      .ifEqual(register: subtitleRegister, value: 1),
                      .setSubtitleStream(1, displayed: true)]
        }
        let k = film0.count
        film0 += [.ifEqual(register: chapterRegister, value: 0),
                  .goto(k + 4),
                  .playPlaylist(filmPlaylist, markInRegister: chapterRegister),
                  .goto(k + 5),
                  .playPlaylist(filmPlaylist),
                  .jumpObject(first)]
        var objects = [MovieObject(commands: film0, resumeIntention: true)]

        var commands: [[[NavCommand]]] = []
        var neighbours: [[[Int]]] = []
        for (p, page) in menu.pages.enumerated() {
            guard !page.buttons.isEmpty else { throw MenuError.invalid("page \(p + 1) has no buttons") }
            guard page.buttons.indices.contains(page.defaultButton) else {
                throw MenuError.invalid("page \(p + 1)'s default button doesn't exist")
            }
            var pageObject: [NavCommand] = [.setButtonPage(button: page.defaultButton, page: 0),
                                            .playPlaylist(menuPlaylist(page: p))]
            if menu.loopSeconds > 0 { pageObject.append(.goto(1)) }
            objects.append(MovieObject(commands: pageObject))
            var pageCommands: [[NavCommand]] = []
            var pageNeighbours: [[Int]] = []
            for (b, button) in page.buttons.enumerated() {
                let where_ = "page \(p + 1), button \(b + 1)"
                var links: [Int] = []
                for n in [button.up, button.down, button.left, button.right] {
                    guard let n else { links.append(b); continue }
                    guard page.buttons.indices.contains(n) else {
                        throw MenuError.invalid("\(where_) points at button \(n + 1), which isn't on the page")
                    }
                    links.append(n)
                }
                pageNeighbours.append(links)
                switch button.action {
                case .playFilm:
                    pageCommands.append([.move(register: chapterRegister, value: 0), .jumpTitle(1)])
                case .playChapter(let c):
                    guard c >= 0, c < max(film.markCount, 1) else {
                        throw MenuError.invalid("\(where_) plays chapter \(c + 1), but the film has \(film.markCount)")
                    }
                    pageCommands.append([.move(register: chapterRegister, value: c), .jumpTitle(1)])
                case .goToPage(let q):
                    guard menu.pages.indices.contains(q) else {
                        throw MenuError.invalid("\(where_) opens page \(q + 1), which doesn't exist")
                    }
                    pageCommands.append([.jumpObject(menuObject(page: q))])
                case .setSubtitles(let on):
                    guard film.subtitleStreams > 0 else {
                        throw MenuError.invalid("\(where_) switches subtitles, but the film has none")
                    }
                    pageCommands.append([.move(register: subtitleRegister, value: on ? 1 : 0), .selectButton(b)])
                }
            }
            commands.append(pageCommands)
            neighbours.append(pageNeighbours)
        }
        let menuEntry = IndexTable.Entry(movieObject: first, interactive: true)
        let index = IndexTable(firstPlayback: menuEntry, topMenu: menuEntry,
                               titles: [IndexTable.Entry(movieObject: 0, interactive: false)])
        return Navigation(objects: objects, index: index, buttonCommands: commands, neighbours: neighbours)
    }

    // MARK: - Authoring

    /// What was authored, for `Scripts/menu-check`: every page's playlist,
    /// default button and buttons (rect, remote neighbours, action, and a
    /// hash of each state image as the player will draw it). The headless
    /// CLI writes it next to the disc as `<name>.menu.json`.
    struct MenuMap: Codable, Equatable {
        struct Action: Codable, Equatable {
            /// playFilm, playChapter, goToPage or setSubtitles.
            var type: String
            /// Chapter index, page index, or 1/0 for subtitles on/off.
            var value: Int?
        }

        struct Button: Codable, Equatable {
            var id: Int
            /// x, y, width, height on the 1920×1080 frame, as authored.
            var rect: [Int]
            /// Button ids; absent means the key leaves the selection alone.
            var up: Int?
            var down: Int?
            var left: Int?
            var right: Int?
            var action: Action
            /// FNV-1a of the palette indices of the normal, selected and
            /// activated images.
            var stateHashes: [UInt32]
        }

        struct Page: Codable, Equatable {
            var playlist: Int
            var defaultButton: Int
            var paletteSize: Int
            var graphicsBytes: Int
            var buttons: [Button]
        }

        var filmPlaylist: Int
        var firstPage: Int
        var loops: Bool
        var filmSubtitles: Bool
        /// Seconds; the pipeline fills these in.
        var chapters: [Double] = []
        var pages: [Page]

        static func action(_ a: MenuAction) -> Action {
            switch a {
            case .playFilm: return Action(type: "playFilm")
            case .playChapter(let n): return Action(type: "playChapter", value: n)
            case .goToPage(let p): return Action(type: "goToPage", value: p)
            case .setSubtitles(let on): return Action(type: "setSubtitles", value: on ? 1 : 0)
            }
        }

        func json() throws -> Data {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try e.encode(self)
        }
    }

    /// `root` is the disc folder (holding BDMV/). `workDir` takes the
    /// intermediate PNG, H.264 and AC-3 files.
    @discardableResult
    func author(_ menu: DiscMenu, disc root: URL, workDir: URL, logger: RunLogger? = nil,
                onLog: (@Sendable (String) -> Void)? = nil) async throws -> MenuMap {
        let fm = FileManager.default
        let bdmv = root.appendingPathComponent("BDMV")
        let filmMPLS = bdmv.appendingPathComponent("PLAYLIST/\(Self.clipName(Self.filmPlaylist)).mpls")
        guard let mplsData = try? Data(contentsOf: filmMPLS) else { throw MenuError.missingFilm(filmMPLS) }
        let film = try PlaylistSummary(mpls: mplsData)
        let nav = try Self.navigation(for: menu, film: film)
        logger?.write("Menu: \(menu.pages.count) page(s), film has \(film.markCount) chapter mark(s), \(film.subtitleStreams) subtitle stream(s)")

        for dir in ["STREAM", "CLIPINF", "PLAYLIST", "BACKUP/CLIPINF", "BACKUP/PLAYLIST"] {
            try fm.createDirectory(at: bdmv.appendingPathComponent(dir), withIntermediateDirectories: true)
        }

        let loops = menu.loopSeconds > 0
        let frames = loops
            ? max(24, Int((menu.loopSeconds * 24000 / 1001).rounded()))
            : 24
        let seconds = Double(frames) * 1001 / 24000
        let silence = workDir.appendingPathComponent("menu-silence.ac3")
        try await runFFmpeg([
            "-hide_banner", "-y", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
            "-t", String(format: "%.3f", seconds + 0.1),
            "-c:a", "ac3", "-b:a", "192k", "-f", "ac3", silence.path
        ], name: "ffmpeg menu silence", logger: logger)
        var map = MenuMap(filmPlaylist: Self.filmPlaylist, firstPage: menu.firstPage, loops: loops,
                          filmSubtitles: film.subtitleStreams > 0, pages: [])
        let allAudio = M2TSMuxer.ac3Frames(try Data(contentsOf: silence))
        let audioFrames = Array(allAudio.prefix(Int((seconds * 48000 / 1536).rounded(.up))))

        for (p, page) in menu.pages.enumerated() {
            try Task.checkCancellation()
            let number = Self.menuPlaylist(page: p)
            let name = Self.clipName(number)

            let png = workDir.appendingPathComponent("menu-\(p).png")
            try Self.writePNG(page.background, to: png)
            let h264 = workDir.appendingPathComponent("menu-\(p).h264")
            try await runFFmpeg(Self.backgroundArguments(png: png, frames: frames, output: h264),
                                name: "ffmpeg menu page \(p + 1)", logger: logger)
            let units = M2TSMuxer.accessUnits(h264: try Data(contentsOf: h264))

            let buttons = page.buttons.enumerated().map { b, button in
                let links = nav.neighbours[p][b]
                return IGSEncoder.Button(rect: button.rect, normal: button.normal, selected: button.selected,
                                         activated: button.activated, up: links[0], down: links[1],
                                         left: links[2], right: links[3], commands: nav.buttonCommands[p][b])
            }
            let display = try IGSEncoder.displaySet(buttons: buttons, defaultButton: nil)
            map.pages.append(MenuMap.Page(
                playlist: number, defaultButton: page.defaultButton, paletteSize: display.paletteSize,
                graphicsBytes: display.codedBytes,
                buttons: page.buttons.enumerated().map { b, button in
                    MenuMap.Button(id: b, rect: [Int(button.rect.minX.rounded()), Int(button.rect.minY.rounded()),
                                                 Int(button.rect.width.rounded()), Int(button.rect.height.rounded())],
                                   up: button.up, down: button.down, left: button.left, right: button.right,
                                   action: MenuMap.action(button.action), stateHashes: display.stateHashes[b])
                }))

            let input = M2TSMuxer.Input(video: units, frameRate: Self.menuFrameRate,
                                        audio: audioFrames, audioBitrateKbps: 192, menu: display)
            let m2ts = bdmv.appendingPathComponent("STREAM/\(name).m2ts")
            let muxed = try M2TSMuxer.mux(input, to: m2ts)

            let streams = Self.menuStreams()
            let clip = ClipInfo(sourcePacketCount: muxed.sourcePackets, pcrPID: TransportStreamPIDs.pcr,
                                presentationStart: muxed.firstPTS / 2, presentationEnd: muxed.endPTS / 2,
                                streams: streams, entryPointPID: TransportStreamPIDs.video,
                                entryPoints: muxed.entryPoints)
            let playlist = Playlist(clipName: name, inTime: muxed.firstPTS / 2, outTime: muxed.endPTS / 2,
                                    streams: streams, still: loops ? .none : .infinite,
                                    marks: [muxed.firstPTS / 2])
            try write(ClipInfoWriter.data(clip), bdmv, "CLIPINF/\(name).clpi")
            try write(PlaylistWriter.data(playlist), bdmv, "PLAYLIST/\(name).mpls")
            logger?.write("Menu page \(p + 1): \(page.buttons.count) buttons, \(display.paletteSize) colours, \(display.codedBytes / 1024) KB of graphics, \(units.count) frames, \(muxed.sourcePackets) packets → STREAM/\(name).m2ts")
            onLog?("  ✓ menu page \(p + 1)")
        }

        try write(MovieObjectWriter.data(nav.objects), bdmv, "MovieObject.bdmv")
        try write(IndexWriter.data(nav.index), bdmv, "index.bdmv")
        return map
    }

    static func menuStreams() -> [BDStream] {
        [BDStream(pid: TransportStreamPIDs.video, kind: .video(format: 6, rate: 1, aspect: 3)),
         BDStream(pid: TransportStreamPIDs.audio, kind: .audio(presentation: 3, sampling: 1, language: menuLanguage)),
         BDStream(pid: TransportStreamPIDs.menu, kind: .menu(language: menuLanguage))]
    }

    /// Writes `BDMV/<path>` and its BDMV/BACKUP copy.
    private func write(_ data: Data, _ bdmv: URL, _ path: String) throws {
        try data.write(to: bdmv.appendingPathComponent(path))
        try data.write(to: bdmv.appendingPathComponent("BACKUP/" + path))
    }

    /// ffmpeg arguments for a still background: 1080p23.976 H.264 that meets
    /// the Blu-ray constraints (level 4.1, four slices, HRD, AUDs, SPS/PPS
    /// on every IDR, one-second GOPs). No B-frames, so decode order is
    /// display order and every frame's DTS equals its PTS.
    static func backgroundArguments(png: URL, frames: Int, output: URL) -> [String] {
        let x264 = [
            "bluray-compat=1", "level=4.1", "keyint=24", "min-keyint=24", "scenecut=0",
            "bframes=0", "ref=1", "aud=1", "nal-hrd=vbr", "repeat-headers=1",
            "colorprim=bt709", "transfer=bt709", "colormatrix=bt709", "slices=4"
        ].joined(separator: ":")
        return [
            "-hide_banner", "-y",
            "-loop", "1", "-framerate", "24000/1001", "-i", png.path,
            "-frames:v", "\(frames)",
            "-vf", "scale=1920:1080:out_color_matrix=bt709:out_range=tv,format=yuv420p",
            "-c:v", "libx264", "-preset", "medium", "-tune", "stillimage",
            "-profile:v", "high", "-level:v", "4.1",
            "-crf", "16", "-maxrate", "15000k", "-bufsize", "15000k",
            "-x264-params", x264,
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
            "-f", "h264", output.path
        ]
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MenuError.invalid("can't write \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw MenuError.invalid("can't write \(url.lastPathComponent)") }
    }

    private func runFFmpeg(_ args: [String], name: String, logger: RunLogger?) async throws {
        let recorder = logger?.beginSubprocess(name: name, executable: ffmpeg, arguments: args)
        do {
            let result = try await ProcessRunner.run(ffmpeg, arguments: args,
                                                     onStderrLine: { recorder?.recordStderr($0) })
            recorder?.finish(exitCode: result.exitCode)
        } catch {
            recorder?.finish(exitCode: -1)
            throw error
        }
    }
}
