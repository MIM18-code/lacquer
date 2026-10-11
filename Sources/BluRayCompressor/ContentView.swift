import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var coordinator = EncodeCoordinator()
    @State private var isDropTargeted = false

    var body: some View {
        HSplitView {
            sidebar
                .padding(16)
                .frame(minWidth: 300, idealWidth: 320, maxWidth: 360)
            mainPanel
                .padding(16)
                .frame(minWidth: 500)
        }
        .onAppear { coordinator.loadTools() }
        .alert("Error", isPresented: .init(
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

                GroupBox("Disc") {
                    Picker("", selection: $coordinator.preset.discSize) {
                        ForEach(DiscSize.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .padding(.vertical, 2)
                }

                GroupBox("Video") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $coordinator.preset.standard) {
                            ForEach(VideoStandard.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        Toggle("Two-pass (slower, better quality)",
                               isOn: $coordinator.preset.twoPass)
                    }
                    .padding(.vertical, 2)
                }

                GroupBox("Audio") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $coordinator.preset.audioBitrateKbps) {
                            Text("448 kbps").tag(448)
                            Text("640 kbps").tag(640)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text("AC-3 up to 5.1 surround. 7.1 sources are downmixed to 5.1; per-job audio track can be overridden in the queue.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }

                GroupBox("Chapters") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $coordinator.preset.chapters.mode) {
                            ForEach(ChaptersMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()

                        if coordinator.preset.chapters.mode == .custom {
                            TextField("00:00, 05:30, 12:00, …",
                                      text: $coordinator.preset.chapters.customText,
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
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $coordinator.preset.outputMode) {
                            ForEach(OutputMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        Text(outputHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }

                toolStatus
                Spacer(minLength: 0)
            }
        }
    }

    private var chaptersHint: String {
        switch coordinator.preset.chapters.mode {
        case .none:
            return "Disc auto-plays on insert. No skip points on the remote."
        case .auto5, .auto10:
            return "Chapter stops let you skip forward/back with Next/Prev. No on-screen menu."
        case .custom:
            return "Comma, newline, or semicolon separated. Use HH:MM:SS, MM:SS, or seconds."
        }
    }

    private var outputHint: String {
        switch coordinator.preset.outputMode {
        case .bdmvFolder:
            return "Full BDMV folder. Burn with Disk Utility or import into Toast/any BD authoring tool."
        case .iso:
            return "UDF 2.50 disc image. Burn with Disk Utility, Toast, or `hdiutil burn`."
        case .m2tsOnly:
            return "Single compliant M2TS. Use this when you want Toast 20 to author on-screen menus."
        }
    }

    private var toolStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if coordinator.tools != nil {
                Label("ffmpeg · ffprobe · tsMuxeR found",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Label("External tools missing",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("See README for install instructions")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Main panel

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            dropZone
            queueCard
            logCard
            actionBar
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "opticaldiscdrive")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Drop one or more video files here")
                .font(.body)
            Button("Choose Files…") { pickFiles() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
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

    private var queueCard: some View {
        GroupBox("Queue") {
            if coordinator.jobs.isEmpty {
                Text("No jobs yet. Drop a video file above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 4) {
                    ForEach(coordinator.jobs) { job in
                        JobRow(
                            job: job,
                            onRemove: { coordinator.removeJob(job) },
                            onReveal: { revealOutput(for: job) },
                            onAttachSubtitle: { attachSubtitle(to: job) },
                            onClearSubtitle: { coordinator.setSubtitle(nil, for: job.id) },
                            onSelectAudio: { idx in coordinator.setAudioStream(idx, for: job.id) },
                            onSelectSubtitleLanguage: { code in
                                coordinator.setSubtitleLanguage(code, for: job.id)
                            }
                        )
                        if job.id != coordinator.jobs.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var logCard: some View {
        GroupBox("Log") {
            ScrollView {
                Text(coordinator.log.isEmpty ? "—" : coordinator.log)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(coordinator.log.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(6)
            }
            .frame(height: 110)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Clear Done") { coordinator.clearDone() }
                .disabled(!coordinator.jobs.contains { $0.status == .done })
            Spacer()
            Button {
                Task { await coordinator.runAll() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: coordinator.isRunning
                          ? "hourglass" : "play.fill")
                    Text(coordinator.isRunning ? "Running…" : "Start Queue")
                }
                .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!coordinator.hasPendingJobs
                      || coordinator.isRunning
                      || coordinator.tools == nil)
        }
    }

    // MARK: - Helpers

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { @MainActor in
                await coordinator.loadInputs(urls)
            }
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
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.setSubtitle(url, for: job.id)
        }
    }

    private func revealOutput(for job: EncodeJob) {
        let target: URL
        switch job.preset.outputMode {
        case .bdmvFolder: target = job.outputURL
        case .iso:        target = job.outputURL.appendingPathExtension("iso")
        case .m2tsOnly:   target = job.outputURL.appendingPathExtension("m2ts")
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

// MARK: - Job row

struct JobRow: View {
    let job: EncodeJob
    let onRemove: () -> Void
    let onReveal: () -> Void
    let onAttachSubtitle: () -> Void
    let onClearSubtitle: () -> Void
    let onSelectAudio: (Int) -> Void
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                statusIcon
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(job.inputURL.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if job.status == .running {
                        HStack(spacing: 6) {
                            Text(job.stage.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ProgressView(value: job.progress)
                                .progressViewStyle(.linear)
                            Text("\(Int(job.progress * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                    } else {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 8)

                if job.status == .done {
                    Button(action: onReveal) {
                        Image(systemName: "folder")
                            .imageScale(.medium)
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal output in Finder")
                }

                if job.status != .running {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.medium)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from queue")
                }
            }

            if job.status == .pending || job.status == .failed {
                trackControls
                    .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var trackControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let info = job.mediaInfo, !info.audioStreams.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    if info.audioStreams.count == 1, let only = info.audioStreams.first {
                        Text("Audio: \(only.displayLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if only.isAmbiguous {
                            ambiguityBadge
                        }
                    } else {
                        Text("Audio:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { job.selectedAudioIndex ?? info.audioStreams.first?.ffmpegIndex ?? 0 },
                            set: { onSelectAudio($0) }
                        )) {
                            ForEach(info.audioStreams) { s in
                                Text(s.displayLabel).tag(s.ffmpegIndex)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        if let selected = info.audioStreams.first(where: {
                            $0.ffmpegIndex == job.selectedAudioIndex
                        }), selected.isAmbiguous {
                            ambiguityBadge
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "captions.bubble")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
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
                    .frame(maxWidth: 160)
                    .help("ISO 639-2/B language code tagged on the PGS subtitle track. Players that filter by preferred language use this tag.")
                    Button("Remove", action: onClearSubtitle)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                } else {
                    Button("Add SRT…", action: onAttachSubtitle)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    Text("(optional, selectable on disc)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var ambiguityBadge: some View {
        Text("layout unknown")
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.18))
            .foregroundStyle(.orange)
            .clipShape(Capsule())
            .help("Source has 8 channels but no layout tag — could be 7.1 or 5.1+Lt/Rt. Verify before encoding.")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch job.status {
        case .pending:
            if let info = job.mediaInfo {
                return "Pending · \(info.width)×\(info.height) · \(formatDuration(info.duration))"
            }
            return "Pending"
        case .running:
            return "Running"
        case .done:
            return "Done · \(job.outputURL.lastPathComponent)"
        case .failed:
            if let msg = job.errorMessage { return "Failed: \(msg)" }
            return "Failed"
        }
    }

    private func formatDuration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}
