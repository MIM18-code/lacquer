import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The menu designer: a sheet where a filmmaker sets up a disc menu and sees
// each page as a TV will draw it. The preview is the hero; settings sit in
// a grouped form beside it. Rendering runs off the main thread and waits
// for the controls to settle before starting.

struct MenuDesignerView: View {
    @Binding var template: MenuTemplate
    let film: URL
    let chapters: [Double]
    let ffmpeg: URL
    let hasSubtitles: Bool

    @StateObject private var model: MenuDesignerModel
    @State private var showSafeAreas = false
    @State private var choosingImage = false
    @Environment(\.dismiss) private var dismiss

    /// `hdrTransfer`: the film's PQ/HLG transfer when its stills need
    /// tonemapping (only pass it when the ffmpeg can tonemap).
    init(template: Binding<MenuTemplate>, film: URL, chapters: [Double], ffmpeg: URL, hasSubtitles: Bool,
         hdrTransfer: String? = nil) {
        _template = template
        self.film = film
        self.chapters = chapters
        self.ffmpeg = ffmpeg
        self.hasSubtitles = hasSubtitles
        _model = StateObject(wrappedValue: MenuDesignerModel(ffmpeg: ffmpeg, hdrTransfer: hdrTransfer))
    }

    private var request: RenderRequest {
        RenderRequest(template: template, chapters: chapters, hasSubtitles: hasSubtitles, page: model.pageIndex)
    }

    var body: some View {
        HStack(spacing: 0) {
            previewColumn
            Divider()
            settingsColumn
        }
        .frame(minWidth: 840, idealWidth: 1180, minHeight: 600, idealHeight: 760)
        .task(id: request) {
            await model.refresh(template: template, film: film, chapters: chapters,
                                hasSubtitles: hasSubtitles, page: model.pageIndex)
        }
        .task(id: film) {
            await model.loadDuration(film: film)
        }
        .onChange(of: chapters) { _ in model.pageIndex = 0 }
    }

    // MARK: Preview

    private var previewColumn: some View {
        VStack(spacing: 12) {
            pagePicker
            MenuPreviewPane(page: model.displayed, selected: model.selectedButton, activated: model.activatedFlash,
                            showSafeAreas: showSafeAreas,
                            onSelect: { model.selectedButton = $0 },
                            onMove: { model.move($0) },
                            onActivate: { model.flashActivated() })
                .overlay(alignment: .topTrailing) {
                    if model.isRendering {
                        ProgressView().controlSize(.small).padding(10)
                    }
                }
            HStack(alignment: .firstTextBaseline) {
                Text(model.selectionDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("TV safe areas", isOn: $showSafeAreas)
                    .toggleStyle(.checkbox)
                    .help("Outlines action-safe (yellow) and title-safe (red). Keep text and buttons inside the red line.")
            }
            if let message = model.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Click a button, or click the preview and use the arrow keys. Return shows the pressed state.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private var pagePicker: some View {
        let count = model.pageCount
        if count > 1 {
            HStack {
                if count <= 4 {
                    Picker("Page", selection: $model.pageIndex) {
                        Text("Menu").tag(0)
                        ForEach(1..<count, id: \.self) { Text(count == 2 ? "Scenes" : "Scenes \($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 420)
                } else {
                    Picker("Page", selection: $model.pageIndex) {
                        Text("Menu").tag(0)
                        ForEach(1..<count, id: \.self) { Text("Scenes, page \($0) of \(count - 1)").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)
                    Stepper("", value: $model.pageIndex, in: 0...(count - 1)).labelsHidden()
                }
                Spacer()
            }
        }
    }

    // MARK: Settings

    private var settingsColumn: some View {
        VStack(spacing: 0) {
            Form {
                Section("Title") {
                    TextField("Title", text: $template.title,
                              prompt: Text(film.deletingPathExtension().lastPathComponent))
                    TextField("Subtitle", text: $template.subtitle, prompt: Text("2026  ·  Directed by …"))
                }

                Section("Style") {
                    Picker("Style", selection: $template.style) {
                        ForEach(MenuStylePreset.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(template.style.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                backgroundSection

                Section("Buttons") {
                    Toggle("Play", isOn: .constant(true)).disabled(true)
                    Toggle("Scenes", isOn: $template.includeScenes)
                        .disabled(chapters.count < 2)
                    if chapters.count < 2 {
                        note("Needs two or more chapters. Set chapters on the job to add a scene page.")
                    }
                    Toggle("Subtitles On / Off", isOn: $template.includeSubtitles)
                        .disabled(!hasSubtitles)
                    if !hasSubtitles {
                        note("Add an .srt file to the job to get subtitle buttons.")
                    }
                }

                if template.includeScenes && chapters.count >= 2 {
                    Section("Scene pages") {
                        Picker("Columns", selection: $template.scenePages.columns) {
                            ForEach(Array(ScenePageSettings.columnRange), id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Picker("Rows", selection: $template.scenePages.rows) {
                            ForEach(Array(ScenePageSettings.rowRange), id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Toggle("Show times", isOn: $template.scenePages.showTimes)
                        let pages = max(1, model.pageCount - 1)
                        note("\(chapters.count) scenes on \(pages) \(pages == 1 ? "page" : "pages").")
                    }
                    Section("Scene names") {
                        ForEach(chapters.indices, id: \.self) { i in
                            TextField(MenuPlanner.timeString(chapters[i]), text: sceneName(i),
                                      prompt: Text("Scene \(i + 1)"))
                        }
                        note("Shown under each thumbnail. Leave one blank to use \"Scene\" and its number.")
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 16)
            .padding(.top, 4)
        }
        .frame(width: 310)
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                template.background = .imageFile(path: url.path)
            }
        }
    }

    private func sceneName(_ i: Int) -> Binding<String> {
        Binding(
            get: { i < template.sceneNames.count ? template.sceneNames[i] : "" },
            set: { value in
                if template.sceneNames.count <= i {
                    template.sceneNames += Array(repeating: "", count: i + 1 - template.sceneNames.count)
                }
                template.sceneNames[i] = String(value.prefix(40))
            }
        )
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Background

    private enum BackgroundKind: Hashable { case frame, image }

    private var backgroundKind: Binding<BackgroundKind> {
        Binding {
            if case .imageFile = template.background { return .image }
            return .frame
        } set: { kind in
            switch kind {
            case .frame:
                if case .filmFrame = template.background { return }
                template.background = .filmFrame(seconds: model.lastFrameSeconds)
            case .image:
                if case .imageFile = template.background { return }
                choosingImage = true
            }
        }
    }

    private var frameSeconds: Binding<Double> {
        Binding {
            if case .filmFrame(let s) = template.background { return s }
            return model.lastFrameSeconds
        } set: { template.background = .filmFrame(seconds: $0) }
    }

    @ViewBuilder
    private var backgroundSection: some View {
        Section("Background") {
            Picker("Source", selection: backgroundKind) {
                Text("Film frame").tag(BackgroundKind.frame)
                Text("Image file").tag(BackgroundKind.image)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch template.background {
            case .filmFrame:
                FramePicker(film: film, model: model, seconds: frameSeconds)
            case .imageFile(let path):
                HStack {
                    Text((path as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { choosingImage = true }
                }
            }
        }
    }
}

// MARK: - Render request

private struct RenderRequest: Equatable {
    var template: MenuTemplate
    var chapters: [Double]
    var hasSubtitles: Bool
    var page: Int
}

// MARK: - Frame picker

private struct FramePicker: View {
    let film: URL
    @ObservedObject var model: MenuDesignerModel
    @Binding var seconds: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.black)
                    if let image = model.framePreview {
                        Image(decorative: image, scale: 1).resizable().interpolation(.medium).scaledToFit()
                    }
                }
                .frame(width: 176, height: 99)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(MenuPlanner.timeString(seconds)).font(.title3).monospacedDigit()
                    if let duration = model.duration {
                        Text("of \(MenuPlanner.timeString(duration))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let duration = model.duration, duration > 1 {
                Slider(value: $seconds, in: 0...max(1, duration - 1))
                    .accessibilityLabel("Background frame time")
            } else {
                Text("Reading film length…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: seconds) {
            await model.loadFramePreview(film: film, seconds: seconds)
        }
    }
}

// MARK: - Preview pane

enum MenuDirection { case up, down, left, right }

/// One page as the TV shows it: background, every button's normal image,
/// and the selected button in its selected state.
private struct MenuPreviewPane: View {
    let page: MenuPage?
    let selected: Int
    let activated: Bool
    let showSafeAreas: Bool
    var onSelect: (Int) -> Void
    var onMove: (MenuDirection) -> Void
    var onActivate: () -> Void

    @State private var focusTrigger = 0

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / 1920
            ZStack(alignment: .topLeading) {
                KeyCatcher(focusTrigger: focusTrigger, onMove: onMove, onActivate: onActivate)
                if let page {
                    Image(decorative: page.background, scale: 1)
                        .resizable().interpolation(.high)
                        .frame(width: geo.size.width, height: geo.size.height)
                    ForEach(page.buttons) { b in
                        let image = b.id == selected ? (activated ? b.activated : b.selected) : b.normal
                        Image(decorative: image, scale: 1)
                            .resizable().interpolation(.high)
                            .frame(width: b.rect.width * scale, height: b.rect.height * scale)
                            .offset(x: b.rect.minX * scale, y: b.rect.minY * scale)
                            .allowsHitTesting(false)
                    }
                    if showSafeAreas {
                        safeArea(MenuGeometry.actionSafe, scale: scale, color: .yellow)
                        safeArea(MenuGeometry.titleSafe, scale: scale, color: .red)
                    }
                    ForEach(page.buttons) { b in
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: b.rect.width * scale, height: b.rect.height * scale)
                            .offset(x: b.rect.minX * scale, y: b.rect.minY * scale)
                            .onTapGesture {
                                onSelect(b.id)
                                focusTrigger += 1
                            }
                            .accessibilityLabel(MenuDesignerModel.describe(b.action))
                            .accessibilityAddTraits(.isButton)
                    }
                } else {
                    Rectangle().fill(Color.black)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu preview")
    }

    private func safeArea(_ rect: CGRect, scale: CGFloat, color: Color) -> some View {
        Rectangle()
            .strokeBorder(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .frame(width: rect.width * scale, height: rect.height * scale)
            .offset(x: rect.minX * scale, y: rect.minY * scale)
            .allowsHitTesting(false)
    }
}

/// Takes arrow keys and Return when the preview has been clicked.
private struct KeyCatcher: NSViewRepresentable {
    var focusTrigger: Int
    var onMove: (MenuDirection) -> Void
    var onActivate: () -> Void

    final class Coordinator { var lastTrigger = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class KeyView: NSView {
        var onMove: (MenuDirection) -> Void = { _ in }
        var onActivate: () -> Void = {}
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123: onMove(.left)
            case 124: onMove(.right)
            case 125: onMove(.down)
            case 126: onMove(.up)
            case 36, 76, 49: onActivate()
            default: super.keyDown(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.onMove = onMove
        v.onActivate = onActivate
        return v
    }

    func updateNSView(_ v: KeyView, context: Context) {
        v.onMove = onMove
        v.onActivate = onActivate
        if context.coordinator.lastTrigger != focusTrigger {
            context.coordinator.lastTrigger = focusTrigger
            DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        }
    }
}

// MARK: - Model

@MainActor
final class MenuDesignerModel: ObservableObject {
    struct Displayed { var index: Int; var page: MenuPage }

    @Published var pageIndex = 0
    @Published var selectedButton = 0
    @Published private(set) var pageCount = 1
    @Published private(set) var displayed: MenuPage?
    @Published private(set) var isRendering = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var duration: Double?
    @Published private(set) var framePreview: CGImage?
    @Published private(set) var activatedFlash = false
    private(set) var lastFrameSeconds: Double = 0

    private let renderer: MenuRenderer
    private var cache: [Int: MenuPage] = [:]
    private var cacheKey: CacheKey?
    private var generation = 0
    private var displayedIndex = -1

    private struct CacheKey: Equatable {
        var template: MenuTemplate
        var chapters: [Double]
        var hasSubtitles: Bool
    }

    init(ffmpeg: URL, hdrTransfer: String? = nil) {
        renderer = MenuRenderer(ffmpeg: ffmpeg, hdrTransfer: hdrTransfer)
    }

    // MARK: Rendering

    func refresh(template: MenuTemplate, film: URL, chapters: [Double], hasSubtitles: Bool, page requested: Int) async {
        let key = CacheKey(template: template, chapters: chapters, hasSubtitles: hasSubtitles)
        if key != cacheKey {
            cacheKey = key
            cache = [:]
        }
        if case .filmFrame(let s) = template.background { lastFrameSeconds = s }
        let count = MenuPlanner.plan(template: template, chapters: chapters, hasSubtitles: hasSubtitles).pages.count
        if count != pageCount { pageCount = count }
        let index = min(max(0, requested), count - 1)
        if index != requested { pageIndex = index }

        if let hit = cache[index] {
            show(hit, index: index)
            return
        }

        // Let the controls settle (a dragged slider fires constantly).
        do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
        generation += 1
        let mine = generation
        isRendering = true
        do {
            let rendered = try await renderer.renderPage(index, template: template, film: film,
                                                         chapters: chapters, hasSubtitles: hasSubtitles)
            if Task.isCancelled { return }
            cache[index] = rendered
            errorMessage = nil
            show(rendered, index: index)
        } catch is CancellationError {
            // A newer request replaced this one.
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
        if mine == generation { isRendering = false }
    }

    private func show(_ page: MenuPage, index: Int) {
        displayed = page
        if index != displayedIndex {
            displayedIndex = index
            selectedButton = page.defaultButton
        } else if selectedButton >= page.buttons.count {
            selectedButton = page.defaultButton
        }
    }

    func loadDuration(film: URL) async {
        duration = await renderer.duration(of: film)
    }

    func loadFramePreview(film: URL, seconds: Double) async {
        do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
        if let image = try? await renderer.previewFrame(film: film, at: seconds) {
            framePreview = image
        }
    }

    // MARK: Interaction

    func move(_ direction: MenuDirection) {
        guard let page = displayed, page.buttons.indices.contains(selectedButton) else { return }
        let b = page.buttons[selectedButton]
        let next: Int?
        switch direction {
        case .up: next = b.up
        case .down: next = b.down
        case .left: next = b.left
        case .right: next = b.right
        }
        if let next, page.buttons.indices.contains(next) { selectedButton = next }
    }

    func flashActivated() {
        activatedFlash = true
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            activatedFlash = false
        }
    }

    var selectionDescription: String {
        guard let page = displayed, page.buttons.indices.contains(selectedButton) else { return " " }
        return Self.describe(page.buttons[selectedButton].action)
    }

    nonisolated static func describe(_ action: MenuAction) -> String {
        switch action {
        case .playFilm: return "Play: starts the film."
        case .playChapter(let c): return "Scene \(c + 1): starts the film at this chapter."
        case .goToPage(let p): return p == 0 ? "Main menu: returns to the first page." : "Opens scene page \(p)."
        case .setSubtitles(let on): return on ? "Subtitles On: turns the subtitle track on." : "Subtitles Off: turns the subtitle track off."
        }
    }
}

// MARK: - Standalone window for development

#if DEBUG
/// `Lacquer --menu-designer FILM [--chapters N] [--no-srt]` opens just the designer.
struct MenuDesignerDebugApp: App {
    var body: some Scene {
        WindowGroup("Menu Designer") {
            MenuDesignerDebugHost()
        }
        .windowResizability(.contentMinSize)
    }
}

private struct MenuDesignerDebugHost: View {
    private struct Setup {
        var film: URL
        var chapters: [Double]
        var ffmpeg: URL
        var hasSubtitles: Bool
    }

    @State private var template = MenuTemplate()
    @State private var setup: Setup?
    @State private var failure: String?

    var body: some View {
        Group {
            if let setup {
                MenuDesignerView(template: $template, film: setup.film, chapters: setup.chapters,
                                 ffmpeg: setup.ffmpeg, hasSubtitles: setup.hasSubtitles)
            } else {
                Text(failure ?? "Opening…").padding(40)
            }
        }
        .task {
            let args = CommandLine.arguments
            guard let path = MenuDebug.option("--menu-designer", in: args) else {
                failure = "usage: --menu-designer FILM [--chapters N] [--no-srt]"
                return
            }
            guard let ffmpeg = MenuDebug.ffmpegURL() else {
                failure = "ffmpeg not found"
                return
            }
            let film = URL(fileURLWithPath: path)
            let renderer = MenuRenderer(ffmpeg: ffmpeg)
            let duration = await renderer.duration(of: film) ?? 600
            let count = Int(MenuDebug.option("--chapters", in: args) ?? "") ?? 8
            template = MenuTemplate.suggested(forFilm: film, duration: duration)
            template.subtitle = "2026  ·  A film by Joshua Land"
            setup = Setup(film: film, chapters: MenuDebug.chapters(count: count, duration: duration),
                          ffmpeg: ffmpeg, hasSubtitles: !args.contains("--no-srt"))
            NSApp.activate(ignoringOtherApps: true)

            // `--snapshot PATH [--click-page N]`: save the window as a PNG and quit.
            if let out = MenuDebug.option("--snapshot", in: args) {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                exit(0)
            }
        }
    }
}
#endif
