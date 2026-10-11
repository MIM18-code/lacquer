import XCTest
@testable import Lacquer

final class StandardTests: XCTestCase {
    func testSuggestedStandardKeepsEveryFrame() {
        XCTAssertEqual(VideoStandard.suggested(forFrameRate: 24000.0 / 1001, interlaced: false), .p1080_2398)
        XCTAssertEqual(VideoStandard.suggested(forFrameRate: 24, interlaced: false), .p1080_24)
        XCTAssertEqual(VideoStandard.suggested(forFrameRate: 25, interlaced: false), .i1080_25)
        XCTAssertEqual(VideoStandard.suggested(forFrameRate: 50, interlaced: false), .i1080_25)
        XCTAssertEqual(VideoStandard.suggested(forFrameRate: 30000.0 / 1001, interlaced: false), .i1080_2997)
        XCTAssertEqual(VideoStandard.suggested(forFrameRate: 60000.0 / 1001, interlaced: false), .i1080_2997)
        XCTAssertEqual(VideoStandard.suggested(forFrameRate: 30000.0 / 1001, interlaced: true), .i1080_2997)
        XCTAssertEqual(VideoStandard.suggested(forFrameRate: 12.5, interlaced: false), .p1080_2398)
    }

    func testRateNotes() {
        let ntsc = 30000.0 / 1001
        XCTAssertNil(VideoStandard.p1080_2398.rateNote(sourceFrameRate: 24000.0 / 1001, sourceInterlaced: false))
        XCTAssertNil(VideoStandard.i1080_2997.rateNote(sourceFrameRate: ntsc, sourceInterlaced: false))
        XCTAssertNil(VideoStandard.i1080_25.rateNote(sourceFrameRate: 50, sourceInterlaced: false))
        XCTAssertNil(VideoStandard.p720_5994.rateNote(sourceFrameRate: ntsc, sourceInterlaced: true))

        guard case .major(let msg)? = VideoStandard.p1080_2398.rateNote(sourceFrameRate: ntsc, sourceInterlaced: false) else {
            return XCTFail("29.97 on 23.976 should be a major mismatch")
        }
        XCTAssertTrue(msg.contains("20%"), msg)
        XCTAssertTrue(msg.contains("1080i29.97"), msg)

        guard case .minor? = VideoStandard.p1080_2398.rateNote(sourceFrameRate: 24, sourceInterlaced: false) else {
            return XCTFail("24 on 23.976 should be minor")
        }
    }

    func testFormatRate() {
        XCTAssertEqual(VideoStandard.formatRate(24), "24")
        XCTAssertEqual(VideoStandard.formatRate(24000.0 / 1001), "23.976")
        XCTAssertEqual(VideoStandard.formatRate(30000.0 / 1001), "29.97")
    }
}

final class FilterChainTests: XCTestCase {
    private func info(fps: Double = 24, interlaced: Bool = false, transfer: String = "", space: String = "") -> MediaInfo {
        MediaInfo(duration: 60, width: 1920, height: 1080, videoCodec: "prores", frameRate: fps,
                  audioStreams: [], sourceIsInterlaced: interlaced,
                  colorTransfer: transfer, colorSpace: space)
    }

    func testDeinterlaceRunsBeforeScale() {
        let vf = BluRayEncoder.videoFilterChain(standard: .p720_5994, source: info(fps: 30000.0 / 1001, interlaced: true),
                                                capabilities: .none)
        XCTAssertTrue(vf.hasPrefix("bwdif=mode=send_field"), vf)
        XCTAssertLessThan(vf.range(of: "bwdif")!.lowerBound, vf.range(of: "scale=")!.lowerBound)
    }

    func testProgressiveToInterlaced() {
        XCTAssertTrue(BluRayEncoder.videoFilterChain(standard: .i1080_25, source: info(fps: 50), capabilities: .none)
            .contains("interlace=scan=tff"))
        XCTAssertTrue(BluRayEncoder.videoFilterChain(standard: .i1080_25, source: info(fps: 25), capabilities: .none)
            .contains("setfield=mode=tff"))
        XCTAssertTrue(BluRayEncoder.videoFilterChain(standard: .i1080_2997, source: info(fps: 50), capabilities: .none)
            .contains("setfield=mode=tff"), "cross-standard must not pair fields")
    }

    func testInterlacedScaleKeepsFields() {
        XCTAssertTrue(BluRayEncoder.videoFilterChain(standard: .i1080_2997, source: info(fps: 30000.0 / 1001, interlaced: true),
                                                     capabilities: .none).contains(":interl=1"))
    }

    func testHDRTonemapOnlyWhenAvailable() {
        let hdr = info(transfer: "smpte2084")
        let with = BluRayEncoder.videoFilterChain(standard: .p1080_24, source: hdr,
                                                  capabilities: .init(canTonemapHDR: true))
        XCTAssertTrue(with.contains("tonemap=tonemap=hable"), with)
        XCTAssertTrue(with.contains("zscale=tin=smpte2084"), with)
        XCTAssertLessThan(with.range(of: "tonemap")!.lowerBound, with.range(of: "scale=1920")!.lowerBound)
        let without = BluRayEncoder.videoFilterChain(standard: .p1080_24, source: hdr, capabilities: .none)
        XCTAssertFalse(without.contains("tonemap"))
    }

    func testSDMatrixConverted() {
        XCTAssertTrue(BluRayEncoder.videoFilterChain(standard: .p1080_2398, source: info(space: "smpte170m"),
                                                     capabilities: .none).contains("in_color_matrix=bt601"))
    }

    func testInterlacedX264Params() {
        XCTAssertTrue(BluRayEncoder.x264Params(standard: .i1080_25).hasSuffix(":tff=1"))
        XCTAssertFalse(BluRayEncoder.x264Params(standard: .p1080_24).contains("tff"))
    }
}

final class AudioTests: XCTestCase {
    private func stream(_ i: Int, ch: Int, layout: String = "", title: String? = nil) -> AudioStreamInfo {
        AudioStreamInfo(ffmpegIndex: i, codec: "pcm_s24le", channels: ch, layout: layout, title: title)
    }

    private func info(_ streams: [AudioStreamInfo]) -> MediaInfo {
        MediaInfo(duration: 60, width: 1920, height: 1080, videoCodec: "prores", frameRate: 24,
                  audioStreams: streams, sourceIsInterlaced: false)
    }

    func testSixMonoTracksBecomeFivePointOne() {
        let i = info((1...6).map { stream($0, ch: 1, layout: "mono") })
        XCTAssertEqual(AudioStreamPicker.bestSource(for: i), .discrete([1, 2, 3, 4, 5, 6], .smpte))
    }

    func testRealSurroundStreamWins() {
        let i = info([stream(1, ch: 6, layout: "5.1")] + (2...7).map { stream($0, ch: 1, layout: "mono") })
        XCTAssertEqual(AudioStreamPicker.bestSource(for: i), .stream(1))
    }

    func testTwoMonoBecomeStereoAndNoAudioIsSilence() {
        XCTAssertEqual(AudioStreamPicker.bestSource(for: info([stream(1, ch: 1), stream(2, ch: 1)])),
                       .discrete([1, 2], .smpte))
        XCTAssertEqual(AudioStreamPicker.bestSource(for: info([])), .silence)
    }

    func testCommentaryLosesTie() {
        let i = info([stream(1, ch: 2, layout: "stereo", title: "Commentary"), stream(2, ch: 2, layout: "stereo")])
        XCTAssertEqual(AudioStreamPicker.bestSource(for: i), .stream(2))
    }

    func testJoinMapsChannelOrder() {
        let src = URL(fileURLWithPath: "/x.mov")
        let i = info((1...6).map { stream($0, ch: 1) })
        let smpte = BluRayEncoder.audioArguments(source: .discrete([1, 2, 3, 4, 5, 6], .smpte), input: src, info: i, bitrateKbps: 640)
        XCTAssertTrue(smpte.contains { $0.hasSuffix("[a0][a1][a2][a3][a4][a5]join=inputs=6:channel_layout=5.1:map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-BL|5.0-BR[aout]") }, "\(smpte)")
        XCTAssertTrue(smpte.contains { $0.hasPrefix("[0:1]asetpts=PTS-STARTPTS[a0];[0:2]asetpts=PTS-STARTPTS[a1]") }, "\(smpte)")
        let film = BluRayEncoder.audioArguments(source: .discrete([1, 2, 3, 4, 5, 6], .film), input: src, info: i, bitrateKbps: 640)
        XCTAssertTrue(film.contains { $0.contains("0.0-FL|1.0-FC|2.0-FR|3.0-BL|4.0-BR|5.0-LFE") }, "\(film)")
    }

    func testStereoBitrateCapped() {
        let args = BluRayEncoder.audioArguments(source: .stream(1), input: URL(fileURLWithPath: "/x.mov"),
                                                info: info([stream(1, ch: 2)]), bitrateKbps: 640)
        XCTAssertEqual(args[args.firstIndex(of: "-b:a")! + 1], "448k")
        XCTAssertEqual(args[args.firstIndex(of: "-ac")! + 1], "2")
    }

    func testAudioOptionsOfferMonoCombos() {
        let labels = info((1...6).map { stream($0, ch: 1) }).audioOptions.map(\.label)
        XCTAssertTrue(labels.contains("Mono tracks 1–6 as 5.1 (L R C LFE Ls Rs)"), "\(labels)")
        XCTAssertTrue(labels.contains("Mono tracks 1–6 as 5.1 (L C R Ls Rs LFE)"))
        XCTAssertTrue(labels.contains("Mono tracks 1–2 as stereo (L R)"))
    }
}

final class PlanTests: XCTestCase {
    private func request(minutes: Double, disc: DiscSize = .bd25, mode: OutputMode = .bdmvFolder, fps: Double = 24000.0 / 1001) -> EncodeRequest {
        let info = MediaInfo(duration: minutes * 60, width: 1920, height: 1080, videoCodec: "prores", frameRate: fps,
                             audioStreams: [AudioStreamInfo(ffmpegIndex: 1, codec: "pcm", channels: 6, layout: "5.1")],
                             sourceIsInterlaced: false)
        var settings = EncodeSettings()
        settings.discSize = disc
        settings.outputMode = mode
        return EncodeRequest(input: URL(fileURLWithPath: "/m.mov"), info: info, settings: settings,
                             standard: .p1080_2398, audio: .stream(1))
    }

    func testFeatureFitsWithoutWarnings() {
        let plan = EncodePlan.make(request(minutes: 100), capabilities: .none, fileExists: { _ in true })
        XCTAssertTrue(plan.fitsOnDisc)
        XCTAssertTrue(plan.warnings.isEmpty, "\(plan.warnings)")
        XCTAssertLessThanOrEqual(plan.videoBitrate, BluRayEncoder.videoBitrateCeiling)
    }

    func testTooLongIsBlockedExceptForM2TS() {
        XCTAssertTrue(EncodePlan.make(request(minutes: 6000), capabilities: .none).isBlocked)
        XCTAssertFalse(EncodePlan.make(request(minutes: 6000, mode: .m2tsOnly), capabilities: .none).isBlocked)
    }

    func testLongTitleGetsQualityWarning() {
        let plan = EncodePlan.make(request(minutes: 480), capabilities: .none)
        XCTAssertFalse(plan.isBlocked)
        XCTAssertEqual(plan.worstLevel, .caution)
    }

    func testFrameRateMismatchWarns() {
        let plan = EncodePlan.make(request(minutes: 10, fps: 30000.0 / 1001), capabilities: .none)
        XCTAssertTrue(plan.warnings.contains { $0.level == .caution && $0.text.contains("stutter") })
    }
}

final class NamingAndTextTests: XCTestCase {
    func testOutputNameDropsQuotes() {
        XCTAssertEqual(OutputNaming.sanitizedBase("My \"Film\""), "My 'Film'")
        XCTAssertEqual(OutputNaming.sanitizedBase(".hidden"), "Disc.hidden")
    }

    func testUniqueBaseSkipsExistingLog() {
        let folder = URL(fileURLWithPath: "/out")
        let taken: Set<String> = ["/out/Reel_BluRay.log"]
        let base = OutputNaming.uniqueBase(in: folder, for: URL(fileURLWithPath: "/src/Reel.mov"),
                                           fileExists: { taken.contains($0) })
        XCTAssertEqual(base.path, "/out/Reel_BluRay_2")
    }

    func testSubtitleDecoding() {
        let cp1252 = Data([0x43, 0x61, 0x66, 0xE9])   // "Café"
        XCTAssertEqual(SubtitlePrep.utf8Text(from: cp1252), "Café")
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("Hi".utf8)
        XCTAssertEqual(SubtitlePrep.utf8Text(from: bom), "Hi")
        let utf16 = "Olá".data(using: .utf16)!   // includes BOM
        XCTAssertEqual(SubtitlePrep.utf8Text(from: utf16), "Olá")
    }

    func testDiscLabel() {
        XCTAssertEqual(BDMVAuthor.discLabel(for: "no \"audio\" here"), "NO_AUDIO_HERE")
        XCTAssertEqual(BDMVAuthor.discLabel(for: "!!!"), "BLURAY")
        XCTAssertEqual(BDMVAuthor.discLabel(for: String(repeating: "a", count: 40)).count, 32)
    }

    func testChapters() {
        var c = ChaptersConfig()
        c.mode = .custom
        c.customText = "5:30; 1:00:00, 99:00:00, junk"
        XCTAssertEqual(c.chapterTimes(duration: 7200), [0, 330, 3600])
        XCTAssertEqual(BDMVAuthor.formatChapterTime(300.9999999), "00:05:01.000")
        XCTAssertEqual(BDMVAuthor.formatChapterTime(.nan), "00:00:00.000")
    }

    func testMetaFile() {
        let author = BDMVAuthor(tsMuxeR: URL(fileURLWithPath: "/t"))
        let iso = author.metaFile(video: URL(fileURLWithPath: "/v.h264"), audio: URL(fileURLWithPath: "/a.ac3"),
                                  frameRate: 24, videoWidth: 1920, videoHeight: 1080, chapters: [0, 300],
                                  subtitle: nil, language: "eng", bluRayMode: true, discLabel: "MY_FILM")
        XCTAssertTrue(iso.hasPrefix("MUXOPT --blu-ray --vbr --vbv-len=500 --label=\"MY_FILM\" --custom-chapters=00:00:00.000;00:05:00.000"), iso)
        let m2ts = author.metaFile(video: URL(fileURLWithPath: "/v.h264"), audio: URL(fileURLWithPath: "/a.ac3"),
                                   frameRate: 24, videoWidth: 1920, videoHeight: 1080, chapters: [0, 300],
                                   subtitle: nil, language: "eng", bluRayMode: false)
        XCTAssertFalse(m2ts.contains("--custom-chapters"))
        XCTAssertFalse(m2ts.contains("--blu-ray"))
    }

    func testSettingsRoundTrip() {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        var s = EncodeSettings()
        s.videoStandard = .i1080_25
        s.outputFolderPath = "/Volumes/Raid/Discs"
        s.chapters.mode = .custom
        s.save(to: defaults)
        XCTAssertEqual(EncodeSettings.load(from: defaults), s)
    }
}

/// Defects found in the 2026-10-11 Codex review.
final class ReviewRegressionTests: XCTestCase {
    func testAnamorphicSourceIsUnsqueezedBeforeFitting() {
        let dv = MediaInfo(duration: 60, width: 720, height: 480, videoCodec: "dvvideo", frameRate: 30000.0 / 1001,
                           audioStreams: [], sourceIsInterlaced: false, sampleAspect: 32.0 / 27)
        let vf = BluRayEncoder.videoFilterChain(standard: .p1080_2398, source: dv, capabilities: .none)
        let unsqueeze = vf.range(of: "scale=trunc(iw*sar/2)*2:ih")
        XCTAssertNotNil(unsqueeze, vf)
        XCTAssertLessThan(unsqueeze!.lowerBound, vf.range(of: "force_original_aspect_ratio")!.lowerBound)
        let square = MediaInfo(duration: 60, width: 1920, height: 1080, videoCodec: "prores", frameRate: 24,
                               audioStreams: [], sourceIsInterlaced: false)
        XCTAssertFalse(BluRayEncoder.videoFilterChain(standard: .p1080_24, source: square, capabilities: .none)
            .contains("iw*sar"))
    }

    func testLateAudioIsPaddedAndEarlyAudioTrimmed() {
        XCTAssertEqual(BluRayEncoder.syncFilter(audioStart: 1.0, videoStart: 0), "adelay=delays=1000:all=1")
        XCTAssertEqual(BluRayEncoder.syncFilter(audioStart: 0, videoStart: 0.5), "atrim=start=0.500000,asetpts=PTS-STARTPTS")
        XCTAssertNil(BluRayEncoder.syncFilter(audioStart: 0.0004, videoStart: 0))

        var late = AudioStreamInfo(ffmpegIndex: 1, codec: "pcm", channels: 2, layout: "stereo")
        late.startTime = 0.25
        let info = MediaInfo(duration: 60, width: 1920, height: 1080, videoCodec: "prores", frameRate: 24,
                             audioStreams: [late], sourceIsInterlaced: false)
        let args = BluRayEncoder.audioArguments(source: .stream(1), input: URL(fileURLWithPath: "/x.mov"),
                                                info: info, bitrateKbps: 448)
        XCTAssertEqual(args[args.firstIndex(of: "-af")! + 1], "adelay=delays=250:all=1")
    }

    func testDiscreteJoinCarriesSyncFilter() {
        var streams = (1...6).map { AudioStreamInfo(ffmpegIndex: $0, codec: "pcm", channels: 1, layout: "mono") }
        for i in streams.indices { streams[i].startTime = 0.1 }
        let info = MediaInfo(duration: 60, width: 1920, height: 1080, videoCodec: "prores", frameRate: 24,
                             audioStreams: streams, sourceIsInterlaced: false)
        let args = BluRayEncoder.audioArguments(source: .discrete([1, 2, 3, 4, 5, 6], .smpte),
                                                input: URL(fileURLWithPath: "/x.mov"), info: info, bitrateKbps: 640)
        XCTAssertTrue(args.contains { $0.contains("[0:1]adelay=delays=100:all=1,asetpts=PTS-STARTPTS[a0]") }, "\(args)")
    }

    func testEachMonoTrackKeepsItsOwnOffset() {
        // Review #2: left starts at 0, right one second later. Each track
        // gets its own alignment instead of the first track's.
        var left = AudioStreamInfo(ffmpegIndex: 1, codec: "pcm", channels: 1, layout: "mono")
        var right = AudioStreamInfo(ffmpegIndex: 2, codec: "pcm", channels: 1, layout: "mono")
        left.startTime = 0
        right.startTime = 1
        let info = MediaInfo(duration: 3, width: 320, height: 180, videoCodec: "h264", frameRate: 24,
                             audioStreams: [left, right], sourceIsInterlaced: false)
        let args = BluRayEncoder.audioArguments(source: .discrete([1, 2], .smpte),
                                                input: URL(fileURLWithPath: "/x.mov"), info: info, bitrateKbps: 448)
        let graph = args[args.firstIndex(of: "-filter_complex")! + 1]
        XCTAssertTrue(graph.hasPrefix("[0:1]asetpts=PTS-STARTPTS[a0];[0:2]adelay=delays=1000:all=1,asetpts=PTS-STARTPTS[a1];"), graph)
    }

    func testCoverArtIsNotTheFilm() throws {
        let json: [String: Any] = [
            "format": ["duration": "12.0"],
            "streams": [
                ["index": 0, "codec_type": "video", "codec_name": "png", "width": 64, "height": 64,
                 "avg_frame_rate": "0/0", "disposition": ["attached_pic": 1]],
                ["index": 1, "codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080,
                 "avg_frame_rate": "24/1", "sample_aspect_ratio": "1:1", "start_time": "0.000000",
                 "disposition": ["attached_pic": 0]],
                ["index": 2, "codec_type": "audio", "codec_name": "aac", "channels": 2, "start_time": "0.042000",
                 "tags": ["handler_name": "SoundHandler"]]
            ]
        ]
        let info = try MediaProbe(ffprobe: URL(fileURLWithPath: "/ffprobe")).parse(json)
        XCTAssertEqual(info.videoStreamIndex, 1)
        XCTAssertEqual(info.width, 1920)
        XCTAssertEqual(info.sampleAspect, 1)
        XCTAssertEqual(info.audioStreams.first?.startTime, 0.042)
        XCTAssertNil(info.audioStreams.first?.title, "generic handler names aren't titles")

        let onlyArt: [String: Any] = [
            "format": ["duration": "200.0"],
            "streams": [["index": 0, "codec_type": "video", "codec_name": "mjpeg", "disposition": ["attached_pic": 1]],
                        ["index": 1, "codec_type": "audio", "codec_name": "aac", "channels": 2]]
        ]
        XCTAssertThrowsError(try MediaProbe(ffprobe: URL(fileURLWithPath: "/ffprobe")).parse(onlyArt))
    }
}

/// Defects from the second Codex review (reviews/codex-review-2-2026-10-11.md).
final class SecondReviewTests: XCTestCase {
    func testReservationGivesConcurrentRunsDifferentNames() throws {
        // #1: two encodes of same-named masters into one folder.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reserve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = URL(fileURLWithPath: "/a/Film.mov")
        let first = try OutputNaming.reserveBase(in: dir, for: input)
        let second = try OutputNaming.reserveBase(in: dir, for: input)
        XCTAssertEqual(first.lastPathComponent, "Film_BluRay")
        XCTAssertEqual(second.lastPathComponent, "Film_BluRay_2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathExtension("log").path))
    }

    func testLongNamesFitTheFilenameLimit() {
        // #9: a legal 247-character source name must leave room for every suffix.
        let long = String(repeating: "x", count: 247)
        let base = OutputNaming.uniqueBase(in: URL(fileURLWithPath: "/out"),
                                           for: URL(fileURLWithPath: "/src/\(long).mov"), fileExists: { _ in false })
        XCTAssertLessThanOrEqual((base.lastPathComponent + "_999.menu.json").utf8.count, 255)
        // Multi-byte characters are cut whole.
        let cut = OutputNaming.truncated(String(repeating: "é", count: 200), maxBytes: 101)
        XCTAssertEqual(cut.utf8.count, 100)
    }

    func testStartedJobKeepsItsStandard() {
        // #14: a running or finished row shows the format it was made with.
        let info = MediaInfo(duration: 60, width: 1920, height: 1080, videoCodec: "prores", frameRate: 25,
                             audioStreams: [], sourceIsInterlaced: false)
        var job = EncodeJob(inputURL: URL(fileURLWithPath: "/a.mov"), mediaInfo: info)
        var settings = EncodeSettings()
        XCTAssertEqual(job.standard(with: settings), .i1080_25)
        job.startedStandard = .i1080_25
        settings.videoStandard = .p1080_24
        XCTAssertEqual(job.standard(with: settings), .i1080_25)
    }
}
