import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject private var coordinator: EncodeCoordinator
    @State private var isDropTargeted = false
    @State private var showLog = false

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 290, idealWidth: 310, maxWidth: 360)
            mainPanel
                .padding(16)
                .frame(minWidth: 520)
        }
        .onAppear { coordinator.loadTools() }
        .alert("Something went wrong", isPresented: .init(
            get: { coordinator.errorMessage != nil },
            set: { if !$0 { coordinator.errorMessage = nil } }
        )) {
            Button("OK") { coordinator.errorMessage = nil }
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings")
                    .font(.title3.bold())
                Text("Jobs that haven't started use these settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GroupBox("Disc") {
                    Picker("", selection: $coordinator.settings.discSize) {
                        ForEach(DiscSize.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .padding(.vertical, 2)
                }

                GroupBox("Video") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $coordinator.settings.videoStandard) {
                            Text("Match each source").tag(VideoStandard?.none)
                            Divider()
                            ForEach(VideoStandard.allCases) { Text($0.rawValue).tag(VideoStandard?.some($0)) }
                        }
                        .labelsHidden()
                        Text(videoHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Two-pass (slower, better quality)",
                               isOn: $coordinator.settings.twoPass)
                    }
                    .padding(.vertical, 2)
                }

                GroupBox("Audio") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $coordinator.settings.audioBitrateKbps) {
                            Text("448 kbps").tag(448)
                            Text("640 kbps").tag(640)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text("AC-3, up to 5.1. Stereo and mono tracks are capped at 448 kbps. 7.1 sources are downmixed to 5.1.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }

                GroupBox("Chapters") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $coordinator.settings.chapters.mode) {
                            ForEach(ChaptersMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()

                        if coordinator.settings.chapters.mode == .custom {
                            TextField("00:00, 05:30, 12:00, …",
                                      text: $coordinator.settings.chapters.customText,
                                      axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2...4)
                        }

                        Text(chaptersHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }

                GroupBox("Output") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $coordinator.settings.outputMode) {
                            ForEach(OutputMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        Text(outputHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider()
                        Text("Save to")
                            .font(.caption.bold())
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(coordinator.settings.outputFolder?.lastPathComponent ?? "Next to each source file")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(coordinator.settings.outputFolderPath ?? "Output goes in the same folder as the source.")
                            Spacer(minLength: 4)
                            Button("Choose…") { chooseOutputFolder() }
                                .controlSize(.small)
                            if coordinator.settings.outputFolderPath != nil {
                                Button {
                                    coordinator.settings.outputFolderPath = nil
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                }
                                .controlSize(.small)
                                .help("Save next to each source file")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if coordinator.tools == nil {
                    Label("Encoding tools not found", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private var videoHint: String {
        if coordinator.settings.videoStandard == nil {
            return "Picks the Blu-ray format that keeps every frame: 23.976 and 24 fps stay 1080p, 25 and 29.97 fps go out as 1080i carrying progressive frames."
        }
        return "Every job uses this format unless you change it on the job."
    }

    private var chaptersHint: String {
        switch coordinator.settings.chapters.mode {
        case .none:
            return "Disc auto-plays on insert. No skip points on the remote."
        case .auto5, .auto10:
            return "Chapter stops let you skip forward/back with Next/Prev. No on-screen menu."
        case .custom:
            return "Comma, newline, or semicolon separated. Use HH:MM:SS, MM:SS, or seconds."
        }
    }

    private var outputHint: String {
        switch coordinator.settings.outputMode {
        case .bdmvFolder:
            return "A BDMV folder. Burn it with Toast or any Blu-ray authoring tool."
        case .iso:
            return "A UDF 2.50 disc image. Burn it with Toast or `hdiutil burn`, or upload it to a duplicator."
        case .m2tsOnly:
            return "One M2TS file. Use this when Toast will author the menus."
        }
    }

    // MARK: - Main panel

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            dropZone
            queue
            logSection
            actionBar
        }
    }

    private var dropZone: some View {
        let compact = !coordinator.jobs.isEmpty
        return HStack(spacing: 12) {
            Image(systemName: "opticaldisc")
                .font(.system(size: compact ? 20 : 30))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(compact ? "Drop more files or folders" : "Drop a finished film master here")
                if !compact {
                    Text("ProRes, DNxHR, H.264 or HEVC in MOV, MP4, MXF or MKV")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Choose Files…") { pickFiles() }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 52 : 96)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

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

    private var queue: some View {
        GroupBox {
            if coordinator.jobs.isEmpty {
                VStack(spacing: 6) {
                    Text("No jobs yet")
                        .font(.callout)
                    Text("Each file you add becomes a disc. Settings on the left apply to every job; the audio, format and subtitles can be changed per job.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
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
                                onSelectSubtitleLanguage: { coordinator.setSubtitleLanguage($0, for: job.id) }
                            )
                            if job.id != coordinator.jobs.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } label: {
            Text("Queue")
        }
        .frame(maxHeight: .infinity)
    }

    private var logSection: some View {
        DisclosureGroup(isExpanded: $showLog) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(coordinator.log.isEmpty ? "—" : coordinator.log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(coordinator.log.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(6)
                    Color.clear.frame(height: 1).id("logEnd")
                }
                .frame(height: 130)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: coordinator.log) { _ in
                    proxy.scrollTo("logEnd", anchor: .bottom)
                }
            }
        } label: {
            Text("Activity")
                .font(.callout)
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Clear Done") { coordinator.clearFinished() }
                .disabled(!coordinator.jobs.contains { $0.status == .done })
            Spacer()
            if coordinator.isRunning {
                Button(role: .destructive) {
                    coordinator.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(minWidth: 80)
                }
                .controlSize(.large)
                .disabled(coordinator.stopRequested)
                .help("Stops the current job and deletes its partial output. Other jobs stay in the queue.")
            }
            Button {
                coordinator.start()
            } label: {
                HStack(spacing: 6) {
                    if coordinator.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(coordinator.isRunning ? "Encoding…" : "Start Queue")
                }
                .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!coordinator.hasPendingJobs
                      || coordinator.isRunning
                      || coordinator.tools == nil)
        }
    }

    // MARK: - Helpers

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { @MainActor in
                await coordinator.loadInputs(urls)
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                statusIcon
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(job.inputURL.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(job.inputURL.path)
                    if job.status == .running {
                        progressLine
                    } else {
                        statusLine
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 10) {
                    if job.status == .done {
                        iconButton("folder", help: "Show the disc in Finder", action: onReveal)
                    }
                    if job.logURL != nil {
                        iconButton("doc.text", help: "Open the job's log", action: onOpenLog)
                    }
                    if job.status.canRetry {
                        iconButton("arrow.clockwise", help: "Put back in the queue", action: onRetry)
                    }
                    if job.status != .running {
                        iconButton("xmark.circle.fill", help: "Remove from queue", action: onRemove)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if job.status.isEditable {
                VStack(alignment: .leading, spacing: 5) {
                    warnings
                    trackControls
                }
                .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).imageScale(.medium)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var progressLine: some View {
        HStack(spacing: 6) {
            Text(job.stage.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
            Text("\(Int(job.progress * 100))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            if let eta = remainingText {
                Text(eta)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .trailing)
            }
        }
    }

    private var remainingText: String? {
        guard let start = job.startedAt, job.progress > 0.02, job.progress < 1 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = elapsed * (1 - job.progress) / job.progress
        let f = DateComponentsFormatter()
        f.allowedUnits = remaining >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: remaining).map { "\($0) left" }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch job.status {
        case .done:
            Text("Done · \(job.outputURL?.lastPathComponent ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .failed:
            Text(job.errorMessage ?? "Failed")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(6)
        case .cancelled:
            Text("Stopped. Partial output was deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .pending, .running:
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var summary: String {
        let standard = job.standard(with: settings)
        let size = ByteCountFormatter.string(fromByteCount: plan.estimatedBytes, countStyle: .file)
        return [
            "\(info.width)×\(info.height) \(VideoStandard.formatRate(info.frameRate)) fps",
            formatDuration(info.duration),
            "→ \(standard.shortName)",
            "\(plan.videoBitrate / 1000) kbps",
            "\(settings.discSize.shortName) \(settings.outputMode.shortName)",
            "~\(size)"
        ].joined(separator: " · ")
    }

    @ViewBuilder
    private var warnings: some View {
        ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, w in
            Label {
                Text(w.text)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: icon(for: w.level))
                    .foregroundStyle(color(for: w.level))
                    .imageScale(.small)
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

    @ViewBuilder
    private var trackControls: some View {
        let suggested = VideoStandard.suggested(forFrameRate: info.frameRate,
                                                interlaced: info.sourceIsInterlaced)
        let followLabel = settings.videoStandard.map { "Sidebar (\($0.shortName))" }
            ?? "Match source (\(suggested.shortName))"
        controlRow("film") {
            Text("Format:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { job.standardOverride },
                set: { onSelectStandard($0) }
            )) {
                Text(followLabel).tag(VideoStandard?.none)
                Divider()
                ForEach(VideoStandard.allCases) { Text($0.rawValue).tag(VideoStandard?.some($0)) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }

        controlRow("waveform") {
            Text("Audio:")
                .font(.caption)
                .foregroundStyle(.secondary)
            let options = info.audioOptions
            if options.count == 1, let only = options.first {
                Text(only.label)
                    .font(.caption)
            } else {
                Picker("", selection: Binding(
                    get: { job.audioSource },
                    set: { onSelectAudio($0) }
                )) {
                    ForEach(options) { opt in
                        Text(opt.label).tag(opt.source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
        }

        controlRow("captions.bubble") {
            if let sub = job.subtitleURL {
                Text("Subtitles: \(sub.lastPathComponent)")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Picker("", selection: Binding(
                    get: { job.subtitleLanguageCode.isEmpty ? "eng" : job.subtitleLanguageCode },
                    set: { onSelectSubtitleLanguage($0) }
                )) {
                    ForEach(Self.subtitleLanguageOptions, id: \.code) { opt in
                        Text("\(opt.label) (\(opt.code))").tag(opt.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .help("Language tag on the subtitle track. Players that pick subtitles by preferred language read this.")
                Button("Remove", action: onClearSubtitle)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            } else {
                Button("Add SRT…", action: onAttachSubtitle)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                Text("optional, viewers can turn them on and off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func controlRow<Content: View>(_ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            content()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .pending:
            if plan.isBlocked {
                Image(systemName: "xmark.octagon").foregroundStyle(.red)
            } else {
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
        }
    }
}
