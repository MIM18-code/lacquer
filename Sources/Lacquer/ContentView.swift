import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Colors that belong to Lacquer itself. Controls keep the system accent;
/// lacquer red only appears on the disc graphic.
enum LacquerStyle {
    static let lacquer = Color(red: 0.72, green: 0.13, blue: 0.15)
    static let lacquerBright = Color(red: 0.89, green: 0.25, blue: 0.25)
    static let discBlack = Color(red: 0.094, green: 0.094, blue: 0.106)
    static let discSheen = Color(red: 0.42, green: 0.44, blue: 0.95)
}

struct ContentView: View {
    @EnvironmentObject private var coordinator: EncodeCoordinator
    @State private var isDropTargeted = false
    @State private var showActivity = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SettingsSidebar()
                .navigationSplitViewColumnWidth(min: 290, ideal: 310, max: 380)
        } detail: {
            VStack(spacing: 0) {
                queueArea
                if showActivity {
                    Divider()
                    activityPanel
                }
                if !coordinator.jobs.isEmpty {
                    Divider()
                    footer
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
                return true
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
        }
        .navigationTitle(AppInfo.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .onAppear { coordinator.loadTools() }
        .alert(coordinator.errorTitle, isPresented: .init(
            get: { coordinator.errorMessage != nil },
            set: { if !$0 { coordinator.errorMessage = nil } }
        )) {
            Button("OK") { coordinator.errorMessage = nil }
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
    }

    private var subtitle: String {
        let pending = coordinator.jobs.filter { $0.status == .pending }.count
        if coordinator.isRunning, let job = coordinator.jobs.first(where: { $0.status == .running }) {
            return "Encoding \(job.inputURL.lastPathComponent)"
        }
        switch pending {
        case 0: return coordinator.jobs.isEmpty ? "Blu-ray discs from a finished master" : "Nothing waiting"
        case 1: return "1 disc waiting"
        default: return "\(pending) discs waiting"
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                pickFiles()
            } label: {
                Label("Add Files", systemImage: "plus")
            }
            .help("Add masters to the queue")

            Toggle(isOn: $showActivity) {
                Label("Activity", systemImage: "list.bullet.rectangle")
            }
            .help("Show what each encode is doing")

            if coordinator.isRunning {
                Button(role: .destructive) {
                    coordinator.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(coordinator.stopRequested)
                .help("Stop the current disc and delete its partial output. The rest of the queue stays. (⌘.)")
            } else {
                Button {
                    coordinator.start()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(!coordinator.hasPendingJobs || coordinator.tools == nil)
                .help("Encode every waiting disc (⌘↩)")
            }
        }
    }

    // MARK: - Queue

    @ViewBuilder
    private var queueArea: some View {
        if coordinator.jobs.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(coordinator.jobs) { job in
                        JobRow(
                            job: job,
                            plan: coordinator.plan(for: job),
                            settings: coordinator.settings,
                            onRemove: { coordinator.removeJob(job) },
                            onRetry: { coordinator.retry(job) },
                            onReveal: { reveal(job.outputURL) },
                            onOpenLog: { if let log = job.logURL { NSWorkspace.shared.open(log) } },
                            onAttachSubtitle: { attachSubtitle(to: job) },
                            onClearSubtitle: { coordinator.setSubtitle(nil, for: job.id) },
                            onSelectAudio: { coordinator.setAudioSource($0, for: job.id) },
                            onSelectStandard: { coordinator.setStandardOverride($0, for: job.id) },
                            onSelectSubtitleLanguage: { coordinator.setSubtitleLanguage($0, for: job.id) },
                            onEditMenu: {
                                if job.menu == nil {
                                    coordinator.setMenu(.suggested(forFilm: job.inputURL, duration: job.mediaInfo.duration),
                                                        for: job.id)
                                }
                                openWindow(id: "menu", value: job.id)
                            },
                            onRemoveMenu: { coordinator.setMenu(nil, for: job.id) }
                        )
                        Divider().padding(.leading, 70)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            DiscBadge(status: .done, progress: 1, blocked: false, showsBadge: false)
                .frame(width: 120, height: 120)
                .accessibilityHidden(true)
            Text("Drop a finished master here")
                .font(.title2.weight(.semibold))
            Text("ProRes, DNxHR, H.264 or HEVC, in MOV, MP4, MXF or MKV. Each file becomes one disc, and you can check its format, audio and fit before anything encodes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Choose Files…") { pickFiles() }
                .controlSize(.large)
                .padding(.top, 4)
            if coordinator.tools == nil {
                Label("The encoding tools weren't found, so files can't be read.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var footer: some View {
        let pending = coordinator.jobs.filter { $0.status == .pending }
        let bytes = pending.reduce(Int64(0)) { total, job in
            let plan = coordinator.plan(for: job)
            return plan.isBlocked ? total : total + plan.estimatedBytes
        }
        let size = formatGB(bytes)
        return HStack {
            Text(pending.isEmpty
                 ? "\(coordinator.jobs.count) in the queue"
                 : "\(pending.count) waiting, about \(size) to write")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            if coordinator.jobs.contains(where: { $0.status.canRetry }) && !coordinator.isRunning {
                Button("Retry All") { coordinator.retryFailed() }
            }
            Button("Clear Done") { coordinator.clearFinished() }
                .disabled(!coordinator.jobs.contains { $0.status == .done })
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var activityPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(coordinator.log.isEmpty ? "Nothing has run yet." : coordinator.log)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(coordinator.log.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
                Color.clear.frame(height: 1).id("logEnd")
            }
            .frame(height: 150)
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear { proxy.scrollTo("logEnd", anchor: .bottom) }
            .onChange(of: coordinator.log) { _ in
                proxy.scrollTo("logEnd", anchor: .bottom)
            }
        }
    }

    // MARK: - Helpers

    private func handleDrop(providers: [NSItemProvider]) {
        // Preserve drop order by indexing into a pre-allocated array.
        let count = providers.count
        var collected: [URL?] = Array(repeating: nil, count: count)
        let lock = NSLock()
        let group = DispatchGroup()

        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadDataRepresentation(
                forTypeIdentifier: UTType.fileURL.identifier
            ) { data, _ in
                defer { group.leave() }
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                lock.lock()
                collected[index] = url
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let urls = collected.compactMap { $0 }
            Task { @MainActor in
                await coordinator.loadInputs(urls)
            }
        }
    }

    private func pickFiles() {
        coordinator.chooseAndAddFiles()
    }

    private func attachSubtitle(to job: EncodeJob) {
        let panel = NSOpenPanel()
        var allowed: [UTType] = [.plainText]
        if let srt = UTType(filenameExtension: "srt") {
            allowed.insert(srt, at: 0)
        }
        panel.allowedContentTypes = allowed
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an .srt subtitle file"
        panel.directoryURL = job.inputURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.setSubtitle(url, for: job.id)
        }
    }

    private func reveal(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Menu designer window

/// Hosts the menu designer for one job in its own window. Edits go straight
/// to the job; the window closes itself if the job leaves the queue.
struct MenuDesignerWindow: View {
    let jobID: UUID
    @EnvironmentObject private var coordinator: EncodeCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let job = coordinator.jobs.first(where: { $0.id == jobID }),
           let ffmpeg = coordinator.tools?.ffmpeg {
            let info = job.mediaInfo
            MenuDesignerView(
                template: Binding(
                    get: { coordinator.jobs.first { $0.id == jobID }?.menu
                        ?? .suggested(forFilm: job.inputURL, duration: info.duration) },
                    set: { coordinator.setMenu($0, for: jobID) }
                ),
                film: job.inputURL,
                chapters: coordinator.chapters(for: job),
                ffmpeg: ffmpeg,
                hasSubtitles: job.subtitleURL != nil,
                hdrTransfer: info.isHDR && coordinator.capabilities.canTonemapHDR ? info.colorTransfer : nil,
                deinterlace: info.sourceIsInterlaced
            )
            .navigationTitle("Menu for \(job.inputURL.lastPathComponent)")
            .disabled(!job.status.isEditable)
        } else {
            Text("This disc is no longer in the queue.")
                .foregroundStyle(.secondary)
                .frame(width: 400, height: 200)
                .onAppear { dismiss() }
        }
    }
}

// MARK: - Settings sidebar

struct SettingsSidebar: View {
    @EnvironmentObject private var coordinator: EncodeCoordinator

    var body: some View {
        Form {
            Section {
                Picker("Size", selection: $coordinator.settings.discSize) {
                    Text("BD-25, single layer").tag(DiscSize.bd25)
                    Text("BD-50, dual layer").tag(DiscSize.bd50)
                }
                Picker("Write", selection: $coordinator.settings.outputMode) {
                    Text("BDMV folder").tag(OutputMode.bdmvFolder)
                    Text("Disc image (.iso)").tag(OutputMode.iso)
                    Text("M2TS for Toast").tag(OutputMode.m2tsOnly)
                }
                LabeledContent("Save to") {
                    HStack(spacing: 6) {
                        Text(coordinator.settings.outputFolder?.lastPathComponent ?? "Next to each master")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(coordinator.settings.outputFolderPath ?? "Each disc is written in the same folder as its master.")
                        Menu {
                            Button("Choose Folder…") { chooseOutputFolder() }
                            if coordinator.settings.outputFolderPath != nil {
                                Button("Next to Each Master") { coordinator.settings.outputFolderPath = nil }
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Change where discs are saved")
                    }
                }
            } header: {
                Text("Disc")
            } footer: {
                Footnote(outputHint)
            }

            Section {
                Picker("Format", selection: $coordinator.settings.videoStandard) {
                    Text("Match each master").tag(VideoStandard?.none)
                    ForEach(VideoStandard.allCases) { Text($0.rawValue).tag(VideoStandard?.some($0)) }
                }
                Toggle("Two-pass encode", isOn: $coordinator.settings.twoPass)
            } header: {
                Text("Video")
            } footer: {
                Footnote(videoHint)
            }

            Section {
                Picker("AC-3", selection: $coordinator.settings.audioBitrateKbps) {
                    Text("448 kbps").tag(448)
                    Text("640 kbps").tag(640)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Audio")
            } footer: {
                Footnote("5.1 uses the rate you pick. Stereo and mono stop at 448 kbps, and 7.1 is folded down to 5.1.")
            }

            Section {
                Picker("Stops", selection: $coordinator.settings.chapters.mode) {
                    Text("None").tag(ChaptersMode.none)
                    Text("Every 5 minutes").tag(ChaptersMode.auto5)
                    Text("Every 10 minutes").tag(ChaptersMode.auto10)
                    Text("At times I list").tag(ChaptersMode.custom)
                }
                if coordinator.settings.chapters.mode == .custom {
                    TextField("Times", text: $coordinator.settings.chapters.customText,
                              prompt: Text("0:00, 5:30, 12:00"), axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2...4)
                }
            } header: {
                Text("Chapters")
            } footer: {
                Footnote(chaptersHint)
            }

            Section {
                EmptyView()
            } footer: {
                Footnote("Changes apply to every disc that hasn't started. Format, audio and subtitles can also be set on each disc.")
            }
        }
        .formStyle(.grouped)
    }

    private var videoHint: String {
        if coordinator.settings.videoStandard == nil {
            return "Keeps every frame: 23.976 and 24 fps stay 1080p; 25 and 29.97 fps go on the disc as 1080i carrying whole frames, since Blu-ray has no 1080p at those rates."
        }
        return "Every disc uses this format unless you change it on the disc."
    }

    private var chaptersHint: String {
        switch coordinator.settings.chapters.mode {
        case .none:
            return "The disc plays straight through with no skip points."
        case .auto5, .auto10:
            return "Next and Previous on the remote jump between stops. There's no on-screen menu."
        case .custom:
            return "Separate times with commas or new lines: 1:02:30, 5:30, or seconds."
        }
    }

    private var outputHint: String {
        switch coordinator.settings.outputMode {
        case .bdmvFolder:
            return "A folder you can burn with Toast or any Blu-ray authoring app."
        case .iso:
            return "One disc image, ready for a duplicator or hdiutil burn."
        case .m2tsOnly:
            return "One video file for building menus in Toast. Chapters aren't included."
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where finished discs are saved"
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.settings.outputFolderPath = url.path
        }
    }
}

/// Disc sizes are sold in decimal gigabytes, so show them that way.
func formatGB(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1_000_000_000
    return gb >= 10 ? String(format: "%.1f GB", gb) : String(format: "%.2f GB", gb)
}

/// Section footnote: left-aligned and wrapping. The grouped form's default
/// footer centres a short line and truncates a long one.
private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Disc badge

/// The job's status drawn as a disc: blank while waiting, a lacquer-red
/// ring filling around the rim while it encodes, a badge when it ends.
struct DiscBadge: View {
    let status: JobStatus
    let progress: Double
    let blocked: Bool
    var showsBadge = true

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let r = rect.width / 2
                let hub = Path(ellipseIn: CGRect(x: center.x - r * 0.3, y: center.y - r * 0.3,
                                                 width: r * 0.6, height: r * 0.6))
                let hole = Path(ellipseIn: CGRect(x: center.x - r * 0.1, y: center.y - r * 0.1,
                                                  width: r * 0.2, height: r * 0.2))
                let disc = Path(ellipseIn: rect)
                if status == .pending || status == .cancelled {
                    // A blank: outline only.
                    ctx.stroke(disc, with: .color(.secondary.opacity(0.55)), lineWidth: 1.5)
                    ctx.stroke(hub, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                } else {
                    ctx.fill(disc, with: .color(LacquerStyle.discBlack))
                    ctx.fill(disc, with: .conicGradient(
                        Gradient(colors: [.clear, LacquerStyle.discSheen.opacity(0.45), .clear, .clear,
                                          LacquerStyle.discSheen.opacity(0.35), .clear, .clear]),
                        center: center, angle: .degrees(-40)))
                    // A faint rim keeps the black disc visible on a dark window.
                    ctx.stroke(disc, with: .color(.white.opacity(0.18)), lineWidth: 1)
                    ctx.fill(hub, with: .color(Color(white: 0.32)))
                    ctx.fill(hole, with: .color(Color(nsColor: .windowBackgroundColor)))
                }
            }
            if status == .running {
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(LacquerStyle.lacquerBright, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1.75)
                    .animation(.linear(duration: 0.4), value: progress)
            }
            if showsBadge, let badge {
                Image(systemName: badge.symbol)
                    .font(.system(size: 13, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, badge.color)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1.5))
                    .offset(x: 13, y: 13)
            }
        }
        .frame(minWidth: 38, minHeight: 38)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var badge: (symbol: String, color: Color)? {
        switch status {
        case .done: return ("checkmark.circle.fill", .green)
        case .failed: return ("exclamationmark.circle.fill", .red)
        case .cancelled: return ("stop.circle.fill", .gray)
        case .pending: return blocked ? ("exclamationmark.circle.fill", .red) : nil
        case .running: return nil
        }
    }

    private var accessibilityText: String {
        switch status {
        case .running: return "Encoding, \(Int(progress * 100)) percent"
        case .pending: return blocked ? "Won't fit" : "Waiting"
        default: return status.rawValue
        }
    }
}

// MARK: - Job row

struct JobRow: View {
    let job: EncodeJob
    let plan: EncodePlan
    let settings: EncodeSettings
    let onRemove: () -> Void
    let onRetry: () -> Void
    let onReveal: () -> Void
    let onOpenLog: () -> Void
    let onAttachSubtitle: () -> Void
    let onClearSubtitle: () -> Void
    let onSelectAudio: (AudioSource) -> Void
    let onSelectStandard: (VideoStandard?) -> Void
    let onSelectSubtitleLanguage: (String) -> Void
    var onEditMenu: () -> Void = {}
    var onRemoveMenu: () -> Void = {}

    @State private var isHovered = false

    /// ISO 639-2/B 3-letter codes for the languages a duplication-house disc
    /// is most likely to ship with. Players that filter subtitle tracks by
    /// preferred language need a real tag, not a wildcard "und".
    private static let subtitleLanguageOptions: [(label: String, code: String)] = [
        ("English",     "eng"),
        ("Spanish",     "spa"),
        ("French",      "fre"),
        ("German",      "ger"),
        ("Italian",     "ita"),
        ("Portuguese",  "por"),
        ("Japanese",    "jpn"),
        ("Korean",      "kor"),
        ("Chinese",     "chi"),
        ("Russian",     "rus"),
        ("Arabic",      "ara"),
        ("Hindi",       "hin"),
        ("Undetermined", "und")
    ]

    private var info: MediaInfo { job.mediaInfo }
    private var standard: VideoStandard { job.standard(with: settings) }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            DiscBadge(status: job.status, progress: job.progress,
                      blocked: job.status == .pending && plan.isBlocked)
                .frame(width: 38, height: 38)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 9) {
                header
                sourceLine
                switch job.status {
                case .running:
                    runningLine
                case .done:
                    doneLine
                case .failed:
                    Text(job.errorMessage ?? "Failed")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(8)
                case .cancelled:
                    Text("Stopped. The partial disc was deleted.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .pending:
                    DiscFillBar(plan: plan, settings: settings)
                }
                if job.status.isEditable {
                    warnings
                    controls
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(isHovered ? Color.primary.opacity(0.03) : .clear)
        .onHover { isHovered = $0 }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(job.inputURL.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(job.inputURL.path)
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                if job.status == .done {
                    iconButton("magnifyingglass", help: "Show the disc in Finder", action: onReveal)
                }
                if job.logURL != nil {
                    iconButton("doc.text", help: "Open this disc's log", action: onOpenLog)
                }
                if job.status.canRetry {
                    iconButton("arrow.clockwise", help: "Put it back in the queue", action: onRetry)
                }
                if job.status != .running {
                    iconButton("xmark", help: "Remove from the queue", action: onRemove)
                }
            }
            .foregroundStyle(.secondary)
            .opacity(isHovered || job.status != .pending ? 1 : 0.55)
        }
    }

    private var sourceLine: some View {
        HStack(spacing: 6) {
            Text(verbatim: "\(info.width)×\(info.height), \(VideoStandard.formatRate(info.frameRate)) fps\(info.sourceIsInterlaced ? " interlaced" : ""), \(formatDuration(info.duration))")
            Image(systemName: "arrow.right")
                .imageScale(.small)
                .accessibilityLabel("becomes")
            Text("\(standard.shortName), \((job.startedOutputMode ?? settings.outputMode).rowName)")
                .foregroundStyle(.primary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    private var runningLine: some View {
        HStack(spacing: 6) {
            Text(job.stage.rawValue)
            Text("\(Int(job.progress * 100))%")
                .monospacedDigit()
                .foregroundStyle(.primary)
            if let eta = remainingText {
                Text(eta).monospacedDigit()
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var doneLine: some View {
        Text(job.outputURL?.lastPathComponent ?? "Done")
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var remainingText: String? {
        guard let start = job.startedAt, job.progress > 0.02, job.progress < 1 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = elapsed * (1 - job.progress) / job.progress
        guard remaining >= 5 else { return nil }
        let f = DateComponentsFormatter()
        f.allowedUnits = remaining >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .short
        return f.string(from: remaining).map { "about \($0) left" }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var warnings: some View {
        if !plan.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                // A failed job already shows its reason; don't repeat it.
                ForEach(Array(plan.warnings.filter { $0.text != job.errorMessage }.enumerated()), id: \.offset) { _, w in
                    Label {
                        Text(w.text)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: icon(for: w.level))
                            .foregroundStyle(color(for: w.level))
                    }
                    .font(.callout)
                    .foregroundStyle(w.level == .info ? .secondary : .primary)
                }
            }
        }
    }

    private func icon(for level: PlanWarning.Level) -> String {
        switch level {
        case .info: return "info.circle"
        case .caution: return "exclamationmark.triangle.fill"
        case .blocking: return "xmark.octagon.fill"
        }
    }

    private func color(for level: PlanWarning.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .caution: return .orange
        case .blocking: return .red
        }
    }

    private var controls: some View {
        let suggested = VideoStandard.suggested(forFrameRate: info.frameRate,
                                                interlaced: info.sourceIsInterlaced)
        let followLabel = settings.videoStandard.map { "Sidebar setting (\($0.shortName))" }
            ?? "Match master (\(suggested.shortName))"
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                fieldLabel("Format")
                Picker("Format for \(job.inputURL.lastPathComponent)", selection: Binding(
                    get: { job.standardOverride },
                    set: { onSelectStandard($0) }
                )) {
                    Text(followLabel).tag(VideoStandard?.none)
                    ForEach(VideoStandard.allCases) { Text($0.rawValue).tag(VideoStandard?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                fieldLabel("Audio")
                let options = info.audioOptions
                if options.count == 1, let only = options.first {
                    Text(only.label)
                        .font(.callout)
                } else {
                    Picker("Audio for \(job.inputURL.lastPathComponent)", selection: Binding(
                        get: { job.audioSource },
                        set: { onSelectAudio($0) }
                    )) {
                        ForEach(options) { opt in
                            Text(opt.label).tag(opt.source)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            GridRow {
                fieldLabel("Subtitles")
                if let sub = job.subtitleURL {
                    HStack(spacing: 8) {
                        Text(sub.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .leading)
                            .fixedSize(horizontal: true, vertical: false)
                        Picker("Subtitle language", selection: Binding(
                            get: { job.subtitleLanguageCode.isEmpty ? "eng" : job.subtitleLanguageCode },
                            set: { onSelectSubtitleLanguage($0) }
                        )) {
                            ForEach(Self.subtitleLanguageOptions, id: \.code) { opt in
                                Text(opt.label).tag(opt.code)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("The language players show for this subtitle track")
                        Button("Remove", action: onClearSubtitle)
                            .buttonStyle(.link)
                    }
                } else {
                    HStack(spacing: 8) {
                        Button("Add .srt…", action: onAttachSubtitle)
                        Text("Viewers can turn them on and off.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if Features.discMenus {
                GridRow {
                    fieldLabel("Menu")
                    if let menu = job.menu {
                        HStack(spacing: 8) {
                            Text("\(menu.style.displayName)\(menu.title.isEmpty ? "" : ", “\(menu.title)”")")
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 260, alignment: .leading)
                                .fixedSize(horizontal: true, vertical: false)
                            Button("Edit…", action: onEditMenu)
                            Button("Remove", action: onRemoveMenu)
                                .buttonStyle(.link)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Button("Add Menu…", action: onEditMenu)
                            Text("Without one, the disc plays as soon as it's inserted.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .controlSize(.small)
        .padding(.top, 2)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}

// MARK: - Disc fill

/// How much of the disc this film will take, and the video bitrate that
/// buys. The bitrate is the number that decides picture quality, so it sits
/// next to the bar instead of in a tooltip.
struct DiscFillBar: View {
    let plan: EncodePlan
    let settings: EncodeSettings

    var body: some View {
        let mbps = Double(plan.videoBitrate) / 1_000_000
        let rate = String(format: "%.1f Mbps", mbps)
        let size = formatGB(plan.estimatedBytes)
        if settings.outputMode == .m2tsOnly {
            Text("About \(size), video at \(rate)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            let disc = settings.discSize
            let fraction = min(Double(plan.estimatedBytes) / Double(disc.capacityBytes), 1)
            let capacity = disc == .bd25 ? "25 GB" : "50 GB"
            HStack(spacing: 12) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(fillColor)
                            .frame(width: max(6, geo.size.width * fraction))
                    }
                }
                .frame(width: 150, height: 6)
                .accessibilityHidden(true)
                Text(plan.isBlocked
                     ? "Won't fit on \(disc.shortName)"
                     : "\(size) of \(capacity), video at \(rate)")
                    .font(.callout)
                    .foregroundStyle(plan.isBlocked ? .red : .secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    private var fillColor: Color {
        if plan.isBlocked { return .red }
        if plan.videoBitrate < BluRayEncoder.videoBitrateQualityFloor { return .orange }
        return Color.accentColor.opacity(0.75)
    }
}
