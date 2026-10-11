import SwiftUI
import AppKit

/// Entry point. `--headless` runs one encode from the command line (used by
/// the smoke tests, and handy for scripting); anything else opens the app.
@main
enum Entry {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            exit(MainActor.assumeIsolated { Snapshot.run(directory: dir) })
        }
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
        WindowGroup("Menu", id: "menu", for: UUID.self) { $jobID in
            if let jobID {
                MenuDesignerWindow(jobID: jobID)
                    .environmentObject(coordinator)
            }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppInfo.name)") { AppDelegate.showAbout() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { coordinator.requestAddFiles = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Queue") {
                Button("Start") { coordinator.start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!coordinator.hasPendingJobs || coordinator.isRunning || coordinator.tools == nil)
                Button("Stop") { coordinator.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!coordinator.isRunning)
                Divider()
                Button("Retry All") { coordinator.retryFailed() }
                    .disabled(coordinator.isRunning || !coordinator.jobs.contains { $0.status.canRetry })
                Button("Clear Done") { coordinator.clearFinished() }
                    .disabled(!coordinator.jobs.contains { $0.status == .done })
            }
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
        // Return keeps encoding; quitting takes a deliberate click.
        alert.addButton(withTitle: "Keep Encoding")
        let quit = alert.addButton(withTitle: "Quit")
        quit.hasDestructiveAction = true
        alert.alertStyle = .warning
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        // Let the job stop and clean up before the app goes away; give up
        // waiting after ten seconds so Quit always works.
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await coordinator.stopAndWait() }
                group.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000) }
                await group.next()
                group.cancelAll()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
