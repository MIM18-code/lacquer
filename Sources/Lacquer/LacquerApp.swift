import SwiftUI
import AppKit

/// Entry point. `--headless` runs one encode from the command line (used by
/// the smoke tests, and handy for scripting); anything else opens the app.
@main
enum Entry {
    static func main() {
        #if DEBUG
        if MenuDebug.isMenuCommand(CommandLine.arguments) {
            MenuDebug.run(CommandLine.arguments)
            return
        }
        #endif
        if CommandLine.arguments.contains("--headless") {
            let task = Task {
                let code = await HeadlessCLI.run(Array(CommandLine.arguments.dropFirst()))
                exit(code)
            }
            // Ctrl-C or kill: cancel the encode so ffmpeg stops and the
            // partial output is cleaned up, then exit.
            var sources: [DispatchSourceSignal] = []
            for sig in [SIGINT, SIGTERM] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler { task.cancel() }
                source.resume()
                sources.append(source)
            }
            withExtendedLifetime(sources) { dispatchMain() }
        } else {
            LacquerApp.main()
        }
    }
}

struct LacquerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = EncodeCoordinator()

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            ContentView()
                .environmentObject(coordinator)
                .frame(minWidth: 860, minHeight: 680)
                .onAppear { appDelegate.coordinator = coordinator }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppInfo.name)") { AppDelegate.showAbout() }
            }
            CommandGroup(replacing: .newItem) { }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: EncodeCoordinator? {
        didSet { flushPendingOpens() }
    }
    /// Files opened from Finder before the window (and its coordinator) exists.
    private var pendingOpens: [URL] = []

    /// "Open With", drops on the Dock icon, and `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpens += urls
        flushPendingOpens()
    }

    private func flushPendingOpens() {
        guard let coordinator, !pendingOpens.isEmpty else { return }
        let urls = pendingOpens
        pendingOpens = []
        Task {
            // Tools load in the window's onAppear; make sure they're ready.
            if coordinator.tools == nil { coordinator.loadTools() }
            await coordinator.loadInputs(urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator, coordinator.isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop encoding and quit?"
        alert.informativeText = "The current job stops and its partial output is deleted. Jobs still in the queue are not saved."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Keep Encoding")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // macOS doesn't kill child processes with their parent; without this
        // ffmpeg would keep encoding after the app is gone.
        ProcessRunner.terminateAll()
    }

    static func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        let credits = """
        Turns a finished film master into a Blu-ray disc: a BDMV folder, a UDF 2.50 ISO, or an M2TS for Toast.

        Made by MindInMotion. Licensed under GPL-3.0.

        Uses FFmpeg (GPL), x264 (GPL) and tsMuxeR (Apache-2.0). Their licenses and source locations are in THIRD_PARTY_NOTICES.md inside the app.
        """
        let attributed = NSMutableAttributedString(string: credits, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor
        ])
        if let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
            attributed.append(NSAttributedString(string: "\n\nOpen third-party notices", attributes: [
                .link: notices,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            ]))
        }
        options[.credits] = attributed
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }
}
