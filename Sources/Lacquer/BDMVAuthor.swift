import Foundation

/// Wraps tsMuxeR. Produces a full BDMV folder, a single M2TS, or — critically
/// for Kunaki-style duplication — a UDF 2.50 Blu-ray ISO. tsMuxeR's own ISO
/// writer is the only Mac-native path to a spec-compliant UDF 2.50 image;
/// `hdiutil makehybrid` silently downgrades to UDF 1.50, which plays in
/// software but fails on hardware Blu-ray players.
struct BDMVAuthor {
    let tsMuxeR: URL

    /// Optional viewer-selectable subtitle track. tsMuxeR converts the SRT to
    /// PGS during muxing, so the resulting disc has soft subs the user can
    /// toggle from the remote, not burned-in pixels.
    struct SubtitleTrack {
        var srt: URL
        var languageCode: String = "eng"
    }

    enum AuthorError: LocalizedError {
        /// tsMuxeR's meta-file format embeds paths inside double quotes with
        /// no documented escape mechanism, so any path containing `"` will
        /// break parsing. We reject up-front rather than silently corrupt.
        case unsupportedPath(URL, reason: String)
        /// tsMuxeR can exit 0 while emitting a 0-byte or truncated file when
        /// a codec parse fails or the volume runs out of space mid-write.
        /// We stat the output and error out so a broken disc never reaches
        /// the duplicator.
        case outputMissingOrEmpty(URL, sizeBytes: Int64)

        var errorDescription: String? {
            switch self {
            case .unsupportedPath(let url, let reason):
                return "Cannot mux from a path \(reason): \(url.path). Move or rename the file and try again."
            case .outputMissingOrEmpty(let url, let size):
                return "tsMuxeR finished but produced an empty or missing output (\(size) bytes at \(url.path)). Check the run log for stderr details."
            }
        }
    }

    static func validatePath(_ url: URL, label: String) throws {
        let p = url.path
        if p.contains("\"") {
            throw AuthorError.unsupportedPath(url, reason: "containing a double-quote (used by the \(label))")
        }
        // The meta file is newline-delimited with no documented quoting for
        // embedded newlines. APFS allows `\n` and `\r` in file names; if
        // such a path landed in the meta file the parser would split mid
        // path and tsMuxeR would silently emit an empty mux. `assertOutputBytes`
        // would catch the empty file, but rejecting up-front is the cleaner
        // story.
        if p.contains("\n") || p.contains("\r") {
            throw AuthorError.unsupportedPath(url, reason: "containing a newline character (used by the \(label))")
        }
    }

    /// Produce a full BDMV folder tree. `chapters` is a list of timestamps in
    /// seconds from the start; empty means auto-play with no skip points.
    func authorBDMV(
        videoH264: URL,
        audioAC3: URL,
        frameRate: Double,
        videoWidth: Int,
        videoHeight: Int,
        outputFolder: URL,
        chapters: [Double] = [],
        subtitle: SubtitleTrack? = nil,
        languageCode: String = "eng",
        logger: RunLogger? = nil
    ) async throws {
        try Self.validatePath(videoH264, label: "video stream")
        try Self.validatePath(audioAC3, label: "audio stream")
        try Self.validatePath(outputFolder, label: "output folder")
        if let subtitle { try Self.validatePath(subtitle.srt, label: "SRT file") }

        let fm = FileManager.default
        if fm.fileExists(atPath: outputFolder.path) {
            try fm.removeItem(at: outputFolder)
        }
        try fm.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        try await runMux(
            videoH264: videoH264,
            audioAC3: audioAC3,
            frameRate: frameRate,
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            chapters: chapters,
            subtitle: subtitle,
            languageCode: languageCode,
            metaParentDir: outputFolder,
            outputTarget: outputFolder,
            bluRayMode: true,
            logger: logger,
            subprocessName: "tsMuxeR (BDMV folder)"
        )

        // tsMuxeR sometimes exits 0 with no real output. Verify the BDMV
        // tree actually got written *and* that the largest stream file has
        // bytes — checking only the filename's existence misses the case
        // where the stream was created but never written to.
        let streamDir = outputFolder
            .appendingPathComponent("BDMV")
            .appendingPathComponent("STREAM")
        let streamContents = (try? fm.contentsOfDirectory(atPath: streamDir.path)) ?? []
        let m2tsFiles = streamContents.filter { $0.hasSuffix(".m2ts") }
        guard !m2tsFiles.isEmpty else {
            throw AuthorError.outputMissingOrEmpty(outputFolder, sizeBytes: 0)
        }
        let largest = m2tsFiles
            .map { streamDir.appendingPathComponent($0) }
            .max { lhs, rhs in
                let l = (try? fm.attributesOfItem(atPath: lhs.path)[.size] as? Int64) ?? 0
                let r = (try? fm.attributesOfItem(atPath: rhs.path)[.size] as? Int64) ?? 0
                return l < r
            }
        if let largest {
            try Self.assertOutputBytes(at: largest, minimum: Self.minimumOutputBytes)
        }

        // Some players complain if CERTIFICATE/ is missing.
        let certDir = outputFolder.appendingPathComponent("CERTIFICATE")
        if !fm.fileExists(atPath: certDir.path) {
            try? fm.createDirectory(at: certDir, withIntermediateDirectories: true)
        }
    }

    /// Produce a single .m2ts file for use in Toast's Blu-ray project, where
    /// Toast will do the menu authoring. Chapter timestamps are accepted
    /// here but intentionally dropped during the mux — chapter marks live
    /// in the BDMV playlist (MPLS), and standalone M2TS has no playlist
    /// to hold them. The coordinator surfaces a UI warning when chapters
    /// are configured for this output mode (see fix #16). Re-add chapters
    /// in Toast when authoring the disc.
    func muxSingleM2TS(
        videoH264: URL,
        audioAC3: URL,
        frameRate: Double,
        videoWidth: Int,
        videoHeight: Int,
        outputFile: URL,
        chapters: [Double] = [],
        subtitle: SubtitleTrack? = nil,
        languageCode: String = "eng",
        logger: RunLogger? = nil
    ) async throws {
        try Self.validatePath(videoH264, label: "video stream")
        try Self.validatePath(audioAC3, label: "audio stream")
        try Self.validatePath(outputFile, label: "output file")
        if let subtitle { try Self.validatePath(subtitle.srt, label: "SRT file") }

        let parent = outputFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true
        )
        try await runMux(
            videoH264: videoH264,
            audioAC3: audioAC3,
            frameRate: frameRate,
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            chapters: chapters,
            subtitle: subtitle,
            languageCode: languageCode,
            metaParentDir: parent,
            outputTarget: outputFile,
            bluRayMode: false,
            logger: logger,
            subprocessName: "tsMuxeR (M2TS only)"
        )
        try Self.assertOutputBytes(at: outputFile, minimum: Self.minimumOutputBytes)
    }

    /// Produce a UDF 2.50 Blu-ray ISO directly. tsMuxeR detects the `.iso`
    /// extension and emits a single ISO image in one pass — no separate
    /// folder-then-image step, no UDF version downgrade.
    func authorISO(
        videoH264: URL,
        audioAC3: URL,
        frameRate: Double,
        videoWidth: Int,
        videoHeight: Int,
        outputISO: URL,
        chapters: [Double] = [],
        subtitle: SubtitleTrack? = nil,
        languageCode: String = "eng",
        discLabel: String? = nil,
        logger: RunLogger? = nil
    ) async throws {
        precondition(outputISO.pathExtension.lowercased() == "iso",
                     "authorISO requires an .iso output URL")
        try Self.validatePath(videoH264, label: "video stream")
        try Self.validatePath(audioAC3, label: "audio stream")
        try Self.validatePath(outputISO, label: "output ISO")
        if let subtitle { try Self.validatePath(subtitle.srt, label: "SRT file") }

        let fm = FileManager.default
        if fm.fileExists(atPath: outputISO.path) {
            try fm.removeItem(at: outputISO)
        }
        let parent = outputISO.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)

        try await runMux(
            videoH264: videoH264,
            audioAC3: audioAC3,
            frameRate: frameRate,
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            chapters: chapters,
            subtitle: subtitle,
            languageCode: languageCode,
            metaParentDir: parent,
            outputTarget: outputISO,
            bluRayMode: true,
            discLabel: discLabel,
            logger: logger,
            subprocessName: "tsMuxeR (UDF 2.50 ISO)"
        )
        // An empty UDF image alone is several hundred KB, so the ISO needs a
        // higher floor than a bare stream file.
        try Self.assertOutputBytes(at: outputISO, minimum: 1_048_576)
    }

    /// A stream file smaller than this means tsMuxeR wrote headers and no
    /// frames. Kept low because a few seconds of simple picture (a logo, a
    /// test clip) legitimately encodes to a few hundred KB.
    static let minimumOutputBytes: Int64 = 32_768

    private static func assertOutputBytes(at url: URL, minimum: Int64) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        if size < minimum {
            throw AuthorError.outputMissingOrEmpty(url, sizeBytes: size)
        }
    }

    // MARK: - Core mux

    private func runMux(
        videoH264: URL,
        audioAC3: URL,
        frameRate: Double,
        videoWidth: Int,
        videoHeight: Int,
        chapters: [Double],
        subtitle: SubtitleTrack?,
        languageCode: String,
        metaParentDir: URL,
        outputTarget: URL,
        bluRayMode: Bool,
        discLabel: String? = nil,
        logger: RunLogger?,
        subprocessName: String
    ) async throws {
        let metaURL = metaParentDir
            .appendingPathComponent("tsmuxer-\(UUID().uuidString).meta")
        let metaText = metaFile(
            video: videoH264,
            audio: audioAC3,
            frameRate: frameRate,
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            chapters: chapters,
            subtitle: subtitle,
            language: languageCode,
            bluRayMode: bluRayMode,
            discLabel: discLabel
        )
        try metaText.write(to: metaURL, atomically: true, encoding: .utf8)
        // The meta file is the most useful single artifact for reproducing a
        // tsMuxeR failure — snapshot it into the log before the deferred
        // cleanup wipes it from disk.
        logger?.captureFile(label: "tsMuxeR meta", at: metaURL)
        defer { try? FileManager.default.removeItem(at: metaURL) }

        let args = [metaURL.path, outputTarget.path]
        let recorder = logger?.beginSubprocess(
            name: subprocessName, executable: tsMuxeR, arguments: args
        )
        do {
            let result = try await ProcessRunner.run(
                tsMuxeR,
                arguments: args,
                onStderrLine: { line in recorder?.recordStderr(line) }
            )
            recorder?.finish(exitCode: result.exitCode)
        } catch {
            recorder?.finish(exitCode: -1)
            throw error
        }
    }

    // MARK: - Meta file

    func metaFile(
        video: URL,
        audio: URL,
        frameRate: Double,
        videoWidth: Int,
        videoHeight: Int,
        chapters: [Double],
        subtitle: SubtitleTrack?,
        language: String,
        bluRayMode: Bool,
        discLabel: String? = nil
    ) -> String {
        // In `--blu-ray` mode tsMuxeR assigns the standard Blu-ray PIDs
        // automatically (0x1011 for the primary video, 0x1100 for the
        // primary audio).
        //
        // Do NOT specify `track=` overrides — tsMuxeR silently ignores video
        // frames ("Processed 0 video frames") when explicit track numbers are
        // given alongside --blu-ray. Do NOT use `--new-audio-pes` either; it
        // produces empty streams when combined with BD-mode AC-3.
        //
        // For M2TS-only output we MUST omit --blu-ray. Otherwise tsMuxeR
        // treats the second CLI argument as a target *directory* and writes
        // a full BDMV folder tree under it instead of the single .m2ts file
        // the user asked for.
        let fps = String(format: "%.3f", frameRate)
        var muxOpts = bluRayMode
            ? "MUXOPT --blu-ray --vbr --vbv-len=500"
            : "MUXOPT --vbr --vbv-len=500"
        // `--custom-chapters` writes PlayListMark entries into the BDMV
        // playlist (MPLS). M2TS-only output has no playlist, so the option
        // is silently dropped by tsMuxeR — emitting it would mislead anyone
        // reading the meta file. Gate on bluRayMode; the coordinator warns
        // the user separately when chapters are configured for M2TS mode.
        if let discLabel, !discLabel.isEmpty {
            muxOpts += " --label=\"\(discLabel)\""
        }
        if !chapters.isEmpty && bluRayMode {
            let formatted = chapters.map { Self.formatChapterTime($0) }.joined(separator: ";")
            muxOpts += " --custom-chapters=\(formatted)"
        }
        var lines = [
            muxOpts,
            "V_MPEG4/ISO/AVC, \"\(video.path)\", fps=\(fps), insertSEI, contSPS, lang=\(language)",
            "A_AC3, \"\(audio.path)\", lang=\(language)"
        ]
        if let subtitle {
            lines.append(subtitleLine(
                subtitle: subtitle,
                videoWidth: videoWidth,
                videoHeight: videoHeight,
                frameRate: fps
            ))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// tsMuxeR's `S_TEXT/UTF8` track type accepts a raw .srt input and
    /// converts it to PGS (bitmap) during a `--blu-ray` mux. The font/sizing
    /// values below match the documented example syntax in the justdan96
    /// tsMuxer USAGE.md (font-name without quotes, font-color in 0xAARRGGBB).
    ///
    /// IMPORTANT: tsMuxer only loads fonts from `/Library/Fonts/` on macOS,
    /// not the system font directories. If "Arial" is not present there
    /// (it isn't on a stock macOS install — Microsoft fonts come with
    /// Office), the subtitle render will fail and the user must install a
    /// .ttf into `/Library/Fonts/`. We log a hint when SRT is in use; see
    /// `EncodeCoordinator.runJob`.
    private func subtitleLine(
        subtitle: SubtitleTrack,
        videoWidth: Int,
        videoHeight: Int,
        frameRate: String
    ) -> String {
        // tsMuxeR treats 24-bit `font-color` as RGB and 32-bit as ARGB. The
        // earlier value of `0x00FFFFFF` (32-bit) was alpha=0 → fully
        // transparent, so the disc would mux fine and play silently with
        // no visible subtitle text. Use 24-bit RGB white to side-step the
        // alpha-byte ambiguity.
        //
        // `font-charset=1` is documented in tsMuxeR's USAGE.md but the
        // bundled 2.7.0 build rejects it at runtime ("Can't load charset 1
        // for font ..."), so we omit it and let tsMuxeR pick the default.
        let parts = [
            "S_TEXT/UTF8, \"\(subtitle.srt.path)\"",
            "font-name=Arial",
            "font-size=65",
            "font-color=0xFFFFFF",
            // Clear of the bottom 5% that TVs with overscan crop.
            "bottom-offset=\(max(24, videoHeight * 7 / 100))",
            "font-border=2",
            "text-align=center",
            "video-width=\(videoWidth)",
            "video-height=\(videoHeight)",
            "fps=\(frameRate)",
            "lang=\(subtitle.languageCode)"
        ]
        return parts.joined(separator: ", ")
    }

    /// Volume label for the ISO: what a computer shows when the disc is
    /// inserted. UDF allows more, but uppercase ASCII letters, digits and
    /// underscores up to 32 characters is what every OS displays cleanly.
    static func discLabel(for name: String) -> String {
        let upper = name.uppercased()
        var out = ""
        for scalar in upper.unicodeScalars {
            if ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.hasSuffix("_") {
                out += "_"
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String(trimmed.prefix(32)).isEmpty ? "BLURAY" : String(trimmed.prefix(32))
    }

    static func formatChapterTime(_ seconds: Double) -> String {
        // Defense-in-depth: NaN, infinity, and negative values are not
        // reachable from any current caller (`ChaptersConfig.chapterTimes`
        // only emits non-negative finite Doubles). But `Int(NaN)` and
        // `Int(.infinity)` trap in Swift, so a future caller bypassing
        // those filters would crash mid-encode. Cheaper to fail-soft to
        // a 0-second timestamp here than to rely on every call site.
        guard seconds.isFinite, seconds >= 0 else { return "00:00:00.000" }
        // Round the entire value to milliseconds first, then split. The
        // earlier `Int(seconds)` truncated and then derived ms from the
        // remainder, which could yield an `ms == 1000` four-digit field
        // (e.g. when floating-point drift in auto-chapter accumulation
        // pushes the fractional part to ≥ 0.9995). Going via integer
        // milliseconds avoids the carry-over entirely.
        //
        // Round up, not to nearest: chapters sit on frame starts that fall
        // between milliseconds (20.0208 s at 23.976), and a mark even 0.1 ms
        // before the chapter's IDR frame makes players seek to the GOP
        // before it. The small epsilon keeps whole milliseconds whole.
        let totalMs = Int((seconds * 1000 - 1e-6).rounded(.up))
        let totalSec = totalMs / 1000
        let h  = totalSec / 3600
        let m  = (totalSec % 3600) / 60
        let s  = totalSec % 60
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
