import AppKit
import SwiftUI

/// `Lacquer --snapshot DIR` renders the main window offscreen, in light and
/// dark appearance, with sample jobs in every state. For checking layout
/// without driving the screen, and for README and website screenshots.
@MainActor
enum Snapshot {
    static func run(directory: URL) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scenes: [(String, (EncodeCoordinator) -> Void)] = [
            ("empty", { _ in }),
            ("queue", populate)
        ]
        for (name, setup) in scenes {
            for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let coordinator = EncodeCoordinator()
                coordinator.tools = ExternalTools(ffmpeg: URL(fileURLWithPath: "/usr/bin/true"),
                                                  ffprobe: URL(fileURLWithPath: "/usr/bin/true"),
                                                  tsMuxeR: URL(fileURLWithPath: "/usr/bin/true"))
                setup(coordinator)
                let url = directory.appendingPathComponent("\(name)-\(appearanceName).png")
                render(coordinator, appearance: appearance, to: url)
                print(url.path)
            }
        }
        return 0
    }

    private static func render(_ coordinator: EncodeCoordinator, appearance: NSAppearance.Name, to url: URL) {
        let size = NSSize(width: 1180, height: 820)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        NSApp.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: ContentView()
            .environmentObject(coordinator)
            .frame(width: size.width, height: size.height))
        window.contentView = host
        // Fully offscreen windows don't draw some layer-backed content, so
        // park this one past the screen's edge and show it there.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle: a few run-loop turns for layout and onAppear.
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    private static func populate(_ c: EncodeCoordinator) {
        func stream(_ i: Int, ch: Int, layout: String) -> AudioStreamInfo {
            AudioStreamInfo(ffmpegIndex: i, codec: "pcm_s24le", channels: ch, layout: layout)
        }
        let feature = MediaInfo(duration: 6130, width: 3840, height: 2160, videoCodec: "prores", frameRate: 24000.0 / 1001,
                                audioStreams: (1...6).map { stream($0, ch: 1, layout: "mono") }, sourceIsInterlaced: false)
        let doc = MediaInfo(duration: 4980, width: 1920, height: 1080, videoCodec: "h264", frameRate: 30000.0 / 1001,
                            audioStreams: [stream(1, ch: 2, layout: "stereo")], sourceIsInterlaced: false)
        let short = MediaInfo(duration: 1270, width: 1920, height: 1080, videoCodec: "prores", frameRate: 25,
                              audioStreams: [stream(1, ch: 6, layout: "5.1")], sourceIsInterlaced: false,
                              colorTransfer: "arib-std-b67")
        let epic = MediaInfo(duration: 14_400, width: 1920, height: 1080, videoCodec: "prores", frameRate: 24,
                             audioStreams: [stream(1, ch: 6, layout: "5.1")], sourceIsInterlaced: false)
        let done = MediaInfo(duration: 840, width: 1920, height: 1080, videoCodec: "prores", frameRate: 24,
                             audioStreams: [stream(1, ch: 2, layout: "stereo")], sourceIsInterlaced: false)

        var running = EncodeJob(inputURL: URL(fileURLWithPath: "/Films/Garbage Day FINAL v12.mov"), mediaInfo: feature)
        running.status = .running
        running.stage = .encodingVideo
        running.progress = 0.42
        running.startedAt = Date().addingTimeInterval(-3100)

        var finished = EncodeJob(inputURL: URL(fileURLWithPath: "/Films/Teaser.mov"), mediaInfo: done)
        finished.status = .done
        finished.outputURL = URL(fileURLWithPath: "/Films/Teaser_BluRay")
        finished.logURL = URL(fileURLWithPath: "/Films/Teaser_BluRay.log")

        var phone = EncodeJob(inputURL: URL(fileURLWithPath: "/Films/Behind the Scenes.mp4"), mediaInfo: doc)
        phone.subtitleURL = URL(fileURLWithPath: "/Films/Behind the Scenes.es.srt")
        phone.subtitleLanguageCode = "spa"

        var failed = EncodeJob(inputURL: URL(fileURLWithPath: "/Films/Short Film HLG.mov"), mediaInfo: short)
        failed.status = .failed
        failed.errorMessage = "Can't write to /Volumes/CARD_A. Choose another output folder in the sidebar."

        let toolong = EncodeJob(inputURL: URL(fileURLWithPath: "/Films/Festival Reel (all shorts).mov"), mediaInfo: epic)

        c.jobs = [finished, running, phone, failed, toolong]
        c.log = "+ Garbage Day FINAL v12.mov  3840×2160  23.976 fps  prores  1:42:10\n    audio: Mono tracks 1–6 as 5.1 (L R C LFE Ls Rs)\n\n▶ Garbage Day FINAL v12.mov\n  1080p23.976 · 28.4 Mbps video · AC-3 640 kbps · two-pass\n"
    }
}
