import CoreGraphics
import XCTest
@testable import Lacquer

// Byte-level tests for the HDMV menu writers. Field offsets follow
// libbluray's parsers (index_parse.c, mobj_parse.c, mpls_parse.c,
// clpi_parse.c, ig_decode.c, pg_decode.c).

private func u16(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) << 8 | Int(b[at + 1]) }
private func u32(_ b: [UInt8], _ at: Int) -> Int { u16(b, at) << 16 | u16(b, at + 2) }
private func hex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var it = s.makeIterator()
    while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
    return out
}

private func solidImage(width: Int, height: Int, red: CGFloat, alpha: CGFloat = 1) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: red, green: 0.2, blue: 0.1, alpha: alpha))
    ctx.fill(CGRect(x: 4, y: 4, width: width - 8, height: height - 8))
    return ctx.makeImage()!
}

final class NavCommandTests: XCTestCase {
    func testOpcodesMatchTsMuxerAndLibbluray() {
        // tsMuxeR's MovieObject: Move GPR10 = 0, then PlayPLatMK 0 at GPR10's mark.
        XCTAssertEqual(NavCommand.move(register: 10, value: 0).bytes, hex("504000010000000a00000000"))
        XCTAssertEqual(NavCommand.playPlaylist(0, markInRegister: 10).bytes, hex("42820000000000000000000a"))
        XCTAssertEqual(NavCommand.jumpTitle(1).bytes, hex("218100000000000100000000"))
        XCTAssertEqual(NavCommand.ifEqual(register: 2, value: 1).bytes, hex("484002000000000200000001"))
        XCTAssertEqual(NavCommand.jumpObject(3).bytes, hex("218000000000000300000000"))
        XCTAssertEqual(NavCommand.playPlaylist(1000).bytes, hex("22800000000003e800000000"))
        XCTAssertEqual(NavCommand.goto(7).bytes, hex("208100000000000700000000"))
        // SetStream: PG stream number flag 0x8000, display flag 0x4000.
        XCTAssertEqual(NavCommand.setSubtitleStream(1, displayed: true).bytes, hex("51c000010000c00100000000"))
        XCTAssertEqual(NavCommand.setSubtitleStream(1, displayed: false).bytes, hex("51c000010000800100000000"))
        XCTAssertEqual(NavCommand.selectButton(2).bytes, hex("51c000038000000200000000"))
        XCTAssertEqual(NavCommand.setButtonPage(button: 1, page: 0).bytes, hex("51c000038000000180000000"))
    }
}

final class MovieObjectAndIndexTests: XCTestCase {
    func testMovieObjectLayout() {
        let objects = [
            MovieObject(commands: [.playPlaylist(0)], resumeIntention: true),
            MovieObject(commands: [.playPlaylist(1000), .goto(0)], menuCallMask: true)
        ]
        let b = [UInt8](MovieObjectWriter.data(objects))
        XCTAssertEqual(Array(b[0..<8]), Array("MOBJ0200".utf8))
        XCTAssertEqual(u32(b, 40), b.count - 44, "length counts everything after it")
        XCTAssertEqual(u16(b, 48), 2)
        XCTAssertEqual(u16(b, 50), 0x8000)          // resume_intention_flag
        XCTAssertEqual(u16(b, 52), 1)
        XCTAssertEqual(Array(b[54..<66]), NavCommand.playPlaylist(0).bytes)
        XCTAssertEqual(u16(b, 66), 0x4000)          // menu_call_mask
        XCTAssertEqual(u16(b, 68), 2)
        XCTAssertEqual(b.count, 70 + 24)
    }

    func testIndexLayout() {
        let table = IndexTable(firstPlayback: .init(movieObject: 1, interactive: true),
                               topMenu: .init(movieObject: 2, interactive: true),
                               titles: [.init(movieObject: 0, interactive: false)])
        let b = [UInt8](IndexWriter.data(table))
        XCTAssertEqual(Array(b[0..<8]), Array("INDX0200".utf8))
        XCTAssertEqual(u32(b, 40), 34)              // AppInfoBDMV length
        let indexes = u32(b, 8)
        XCTAssertEqual(indexes, 78)
        XCTAssertEqual(u32(b, indexes), b.count - indexes - 4)
        // First Playback: HDMV object, interactive, object 1.
        XCTAssertEqual(u32(b, indexes + 4), 0x4000_0000)
        XCTAssertEqual(u16(b, indexes + 8), 0x4000)
        XCTAssertEqual(u16(b, indexes + 10), 1)
        // Top Menu: object 2.
        XCTAssertEqual(u16(b, indexes + 22), 2)
        // One title, a movie, object 0.
        XCTAssertEqual(u16(b, indexes + 28), 1)
        XCTAssertEqual(u32(b, indexes + 30), 0x4000_0000)
        XCTAssertEqual(u16(b, indexes + 34), 0)
        XCTAssertEqual(u16(b, indexes + 36), 0)
    }
}

final class PlaylistTests: XCTestCase {
    /// 00000.mpls that tsMuxeR 2.7.0 wrote for a 60 s film with three
    /// chapters, AC-3 and a PG subtitle track.
    static let tsMuxerFilm = hex(
        "4d504c53303230300000003a000000a6000000000000000000000000000000000000000000000000000000"
        + "0e000100000000000000000000400000000068000000010000006030303030304d325453000100019bfcc0"
        + "01c532d7000000000000000000000000003e00000101010000000000000000000901101100000000000005"
        + "1b6100000009011100000000000000058131656e67090112000000000000000590656e67000000002c0003"
        + "00010000019bfcc0ffff000000000001000001a9b860ffff000000000001000001b77400ffff00000000")

    func testWriterReproducesTsMuxerFilmPlaylist() {
        let pl = Playlist(
            clipName: "00000", inTime: 0x019B_FCC0, outTime: 0x01C5_32D7,
            streams: [BDStream(pid: 0x1011, kind: .video(format: 6, rate: 1, aspect: 3)),
                      BDStream(pid: 0x1100, kind: .audio(presentation: 3, sampling: 1, language: "eng")),
                      BDStream(pid: 0x1200, kind: .subtitles(language: "eng"))],
            marks: [0x019B_FCC0, 0x01A9_B860, 0x01B7_7400])
        XCTAssertEqual([UInt8](PlaylistWriter.data(pl)), Self.tsMuxerFilm)
    }

    func testSummaryOfTsMuxerPlaylist() throws {
        let s = try PlaylistSummary(mpls: Data(Self.tsMuxerFilm))
        XCTAssertEqual(s, PlaylistSummary(markCount: 3, subtitleStreams: 1, audioStreams: 1))
    }

    func testMenuPlaylistHasIGEntryAndStill() throws {
        let pl = Playlist(clipName: "01000", inTime: 27_000_000, outTime: 27_675_000,
                          streams: HDMVMenuAuthor.menuStreams(), still: .infinite, marks: [27_000_000])
        let b = [UInt8](PlaylistWriter.data(pl))
        let item = u32(b, 8) + 10
        XCTAssertEqual(Array(b[item + 2..<item + 11]), Array("01000M2TS".utf8))
        XCTAssertEqual(b[item + 31], 2, "still_mode infinite")
        let stn = item + 34
        XCTAssertEqual(Array(b[stn + 4..<stn + 8]), [1, 1, 0, 1], "video, audio, no PG, one IG")
        // The IG entry is last: stream_entry (10 bytes) then attributes.
        let ig = stn + 2 + u16(b, stn) - 16
        XCTAssertEqual(u16(b, ig + 2), 0x1400)
        XCTAssertEqual(b[ig + 11], 0x91)
        XCTAssertEqual(Array(b[ig + 12..<ig + 15]), Array("eng".utf8))
        let summary = try PlaylistSummary(mpls: Data(b))
        XCTAssertEqual(summary.markCount, 1)
    }
}

final class ClipInfoTests: XCTestCase {
    func testLayoutAndEPMap() {
        let entries = [EntryPoint(pts: 54_000_000, sourcePacket: 300, byteLength: 100_000),
                       EntryPoint(pts: 54_090_090, sourcePacket: 140_000, byteLength: 300_000)]
        let clip = ClipInfo(sourcePacketCount: 160_000, pcrPID: 0x1001,
                            presentationStart: 27_000_000, presentationEnd: 27_675_000,
                            streams: HDMVMenuAuthor.menuStreams(), entryPointPID: 0x1011, entryPoints: entries)
        let b = [UInt8](ClipInfoWriter.data(clip))
        XCTAssertEqual(Array(b[0..<8]), Array("HDMV0200".utf8))
        XCTAssertEqual(u32(b, 52), 6_000_000)       // TS_recording_rate
        XCTAssertEqual(u32(b, 56), 160_000)         // number_of_source_packets
        XCTAssertEqual(Array(b[191..<195]), Array("HDMV".utf8))

        let seq = u32(b, 8)
        XCTAssertEqual(seq % 4, 0)
        XCTAssertEqual(u16(b, seq + 12), 0x1001)    // PCR PID
        XCTAssertEqual(u32(b, seq + 18), 27_000_000)
        XCTAssertEqual(u32(b, seq + 22), 27_675_000)

        let prog = u32(b, 12)
        XCTAssertEqual(b[prog + 5], 1)              // one program sequence
        XCTAssertEqual(u16(b, prog + 10), 0x0100)   // PMT PID
        XCTAssertEqual(b[prog + 12], 3)             // streams
        XCTAssertEqual(u16(b, prog + 14), 0x1011)
        XCTAssertEqual(b[prog + 16], 21)            // coding info length
        XCTAssertEqual(Array(b[prog + 17..<prog + 19]), [0x1B, 0x61])

        let cpi = u32(b, 16)
        XCTAssertEqual(u16(b, cpi + 4) & 0xF, 1)    // CPI_type EP_map
        let map = cpi + 6
        XCTAssertEqual(b[map + 1], 1)
        XCTAssertEqual(u16(b, map + 2), 0x1011)
        let packed = (UInt64(u32(b, map + 4)) << 16) | UInt64(u16(b, map + 8))
        XCTAssertEqual((packed >> 34) & 0xF, 1, "EP_stream_type video")
        XCTAssertEqual((packed >> 18) & 0xFFFF, 2, "SPN crosses a 2^17 boundary: two coarse entries")
        XCTAssertEqual(packed & 0x3FFFF, 2, "two fine entries")
        let stream = map + u32(b, map + 10)
        let fine = stream + u32(b, stream)
        let f1 = u32(b, fine + 4)
        XCTAssertEqual(f1 >> 28, 3, "300 KB I frame")
        XCTAssertEqual((f1 >> 17) & 0x7FF, Int((54_090_090 >> 9) & 0x7FF))
        XCTAssertEqual(f1 & 0x1FFFF, 140_000 & 0x1FFFF)
        let coarse2 = stream + 4 + 8
        XCTAssertEqual(u32(b, coarse2) >> 14, 1, "second coarse entry refers to fine entry 1")
        XCTAssertEqual(u32(b, coarse2 + 4), 140_000)
        XCTAssertEqual(u32(b, 20), b.count - 4, "empty ClipMark is last")
    }
}

final class IGSEncoderTests: XCTestCase {
    func testRLERoundTripAndCodes() {
        let width = 400
        var row: [UInt8] = []
        row += [UInt8](repeating: 0, count: 70)     // long transparent run
        row += [5]                                  // single pixel
        row += [6, 6]                               // two pixels stay literal
        row += [UInt8](repeating: 7, count: 3)      // shortest coded run
        row += [UInt8](repeating: 8, count: 64)     // long coded run
        row += [UInt8](repeating: 0, count: 3)
        row += [UInt8](repeating: 9, count: width - row.count)
        let pixels = row + row.reversed()
        let rle = RLE.encode(pixels, width: width, height: 2)
        XCTAssertEqual(RLE.decode(rle, width: width, height: 2), pixels)
        XCTAssertEqual(Array(rle[0..<3]), [0x00, 0x40, 70], "transparent run of 70")
        XCTAssertEqual(Array(rle[3..<6]), [5, 6, 6])
        XCTAssertEqual(Array(rle[6..<9]), [0x00, 0x83, 7])
        XCTAssertEqual(Array(rle[9..<13]), [0x00, 0xC0, 64, 8])
        XCTAssertEqual(Array(rle[13..<15]), [0x00, 3])
    }

    func testPaletteKeepsFewColoursExactly() {
        let img = RGBAImage(width: 2, height: 2, pixels: [255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 0, 0, 255, 0, 0, 255])
        var palette = PaletteQuantizer.palette(for: [img])
        XCTAssertEqual(palette.colors.count, 2)
        let idx = palette.indices(for: img)
        XCTAssertEqual(idx[2], 0, "transparent pixel maps to entry 0")
        XCTAssertEqual(idx[0], idx[3])
        XCTAssertNotEqual(idx[0], idx[1])
        let def = palette.definition()
        XCTAssertEqual(Array(def[2..<7]), [0, 16, 128, 128, 0], "entry 0 is transparent")
        // Pure red in BT.709 limited range: Y 63, Cb 102, Cr 240.
        let red = palette.colors.firstIndex { $0 == [255, 0, 0, 255] }! + 1
        let entry = def[(2 + 5 * red)..<(2 + 5 * red + 5)]
        XCTAssertEqual(Array(entry), [UInt8(red), 63, 240, 102, 255])
    }

    func testPaletteReducesManyColours() {
        var px: [UInt8] = []
        for i in 0..<1000 { px += [UInt8(i % 256), UInt8((i / 4) % 256), UInt8((i * 7) % 256), 255] }
        let img = RGBAImage(width: 1000, height: 1, pixels: px)
        var palette = PaletteQuantizer.palette(for: [img])
        XCTAssertLessThanOrEqual(palette.colors.count, 255)
        XCTAssertGreaterThan(palette.colors.count, 200)
        XCTAssertFalse(palette.indices(for: img).contains(0))
    }

    private func button(_ x: Int, commands: [NavCommand], size: Int = 64) -> IGSEncoder.Button {
        IGSEncoder.Button(rect: CGRect(x: x, y: 100, width: size, height: 32),
                          normal: solidImage(width: size, height: 32, red: 0.1),
                          selected: solidImage(width: size, height: 32, red: 0.9),
                          activated: solidImage(width: size, height: 32, red: 1, alpha: 0.5),
                          up: 0, down: 1, left: 0, right: 1, commands: commands)
    }

    func testDisplaySetStructure() throws {
        let set = try IGSEncoder.displaySet(
            buttons: [button(100, commands: [.move(register: 0, value: 0), .jumpTitle(1)]),
                      button(300, commands: [.jumpObject(2)])],
            defaultButton: 1)
        XCTAssertEqual(set.segments.map { $0.bytes[0] }, [0x18, 0x14] + [UInt8](repeating: 0x15, count: 8) + [0x80])
        for s in set.segments { XCTAssertEqual(u16(s.bytes, 1), s.bytes.count - 3) }

        let ics = set.segments[0].bytes
        XCTAssertEqual(u16(ics, 3), 1920)
        XCTAssertEqual(u16(ics, 5), 1080)
        XCTAssertEqual(ics[7] >> 4, 1, "23.976")
        XCTAssertEqual(ics[10], 0x80, "epoch start")
        XCTAssertEqual(ics[11], 0xC0, "first and last in sequence")
        XCTAssertEqual(Int(ics[12]) << 16 | u16(ics, 13), ics.count - 15)
        XCTAssertEqual(ics[15], 0, "multiplexed, always-on")
        let page = 15 + 1 + 10 + 3 + 1             // model, timeouts, user timeout, page count
        XCTAssertEqual(ics[page], 0, "page id")
        let afterEffects = page + 2 + 8 + 4
        XCTAssertEqual(ics[afterEffects], 1, "activated animation runs at the frame rate")
        XCTAssertEqual(u16(ics, afterEffects + 1), 1, "default selected button")
        XCTAssertEqual(u16(ics, afterEffects + 3), 0xFFFF)
        XCTAssertEqual(ics[afterEffects + 6], 2, "one BOG per button")
        let b0 = afterEffects + 7 + 3               // BOG header, then the button
        XCTAssertEqual(u16(ics, b0), 0)
        XCTAssertEqual(u16(ics, b0 + 5), 100)       // x
        XCTAssertEqual(u16(ics, b0 + 7), 100)       // y
        XCTAssertEqual(u16(ics, b0 + 11), 1, "down neighbour")
        XCTAssertEqual(u16(ics, b0 + 17), 0, "normal object")
        XCTAssertEqual(u16(ics, b0 + 23), 1, "selected object")
        XCTAssertEqual(u16(ics, b0 + 29), 2, "activated animation starts at object 2")
        XCTAssertEqual(u16(ics, b0 + 31), 3, "and ends at object 3: a play-once lock on the remote")
        // Button 1's objects start at 4.
        let b1 = b0 + 35 + 2 * 12 + 3
        XCTAssertEqual(u16(ics, b1), 1)
        XCTAssertEqual(u16(ics, b1 + 17), 4)
        XCTAssertEqual(u16(ics, b0 + 33), 2, "two commands")
        XCTAssertEqual(Array(ics[(b0 + 35)..<(b0 + 47)]), NavCommand.move(register: 0, value: 0).bytes)

        // Object 0: first and last fragment; data length counts width and height.
        let ods = set.segments[2].bytes
        XCTAssertEqual(u16(ods, 3), 0)
        XCTAssertEqual(ods[6], 0xC0)
        XCTAssertEqual(Int(ods[7]) << 16 | u16(ods, 8), ods.count - 10)
        XCTAssertEqual(u16(ods, 10), 64)
        XCTAssertEqual(u16(ods, 12), 32)
        XCTAssertNotNil(RLE.decode(Array(ods[14...]), width: 64, height: 32))
    }

    func testLargeObjectIsFragmented() {
        var rle = [UInt8](repeating: 0x07, count: 150_000)
        rle[0] = 0x05
        let segs = IGSEncoder.objectDefinition(id: 4, width: 600, height: 250, rle: rle)
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs.map { $0.bytes[6] }, [0x80, 0x00, 0x40])
        XCTAssertTrue(segs.allSatisfy { u16($0.bytes, 3) == 4 && $0.bytes.count - 3 <= IGSEncoder.maxSegmentBody })
        let joined = segs.flatMap { Array($0.bytes[7...]) }
        XCTAssertEqual(Int(joined[0]) << 16 | Int(joined[1]) << 8 | Int(joined[2]), rle.count + 4)
        XCTAssertEqual(joined.count, rle.count + 7)
    }

    func testNoDefaultButtonLeavesItToPSR10() throws {
        let set = try IGSEncoder.displaySet(buttons: [button(100, commands: [])], defaultButton: nil)
        XCTAssertEqual(u16(set.segments[0].bytes, 45), 0xFFFF)
    }

    func testTimestampsRespectDecodeOrder() throws {
        var set = try IGSEncoder.displaySet(buttons: [button(100, commands: [])], defaultButton: 0)
        let arrivals = set.segments.indices.map { Int64(54_000_000 + 100 * $0) }
        let pts = set.assignTimestamps(arrivals90k: arrivals)
        let ics = set.segments[0]
        XCTAssertEqual(ics.dts, arrivals[0])
        XCTAssertEqual(ics.pts, pts)
        XCTAssertGreaterThanOrEqual(pts, ics.dts + IGDisplaySet.planeClearTicks)
        var lastPTS = ics.dts
        for (i, s) in set.segments.enumerated() where s.hasDTS && i > 0 {
            XCTAssertGreaterThanOrEqual(s.dts, arrivals[i], "decodes after arriving")
            XCTAssertGreaterThanOrEqual(s.dts, lastPTS, "objects decode one at a time")
            XCTAssertGreaterThan(s.pts, s.dts)
            lastPTS = s.pts
        }
        XCTAssertLessThanOrEqual(set.segments.last!.pts, pts)
        set.setTimeouts(0x1_2345_6789)
        XCTAssertEqual(Array(set.segments[0].bytes[16..<26]), [0x01, 0x23, 0x45, 0x67, 0x89, 0x01, 0x23, 0x45, 0x67, 0x89])
    }
}

final class M2TSMuxerTests: XCTestCase {
    private func annexB(frames: Int) -> Data {
        var d: [UInt8] = []
        for k in 0..<frames {
            d += [0, 0, 0, 1, 0x09, 0x10]                      // AUD
            d += [0, 0, 1, k % 24 == 0 ? 0x65 : 0x41]          // IDR or P slice
            d += [UInt8](repeating: UInt8(k & 0xFF), count: k % 24 == 0 ? 20_000 : 900)
        }
        return Data(d)
    }

    func testAccessUnitsAndAC3Frames() {
        let units = M2TSMuxer.accessUnits(h264: annexB(frames: 30))
        XCTAssertEqual(units.count, 30)
        XCTAssertEqual(units.filter(\.isKeyframe).count, 2)
        XCTAssertEqual(units[0].data.count, 6 + 4 + 20_000)
        // 192 kbit/s, 48 kHz AC-3 frames are 768 bytes.
        var frame = [UInt8](repeating: 0, count: 768)
        frame[0] = 0x0B; frame[1] = 0x77; frame[4] = 0x14     // fscod 0, frmsizecod 20
        XCTAssertEqual(M2TSMuxer.ac3Frames(Data(frame + frame + frame)).count, 3)
    }

    func testMuxedClipIsWellFormed() throws {
        let units = M2TSMuxer.accessUnits(h264: annexB(frames: 48))
        let ig = try IGSEncoder.displaySet(
            buttons: [IGSEncoder.Button(rect: CGRect(x: 200, y: 200, width: 300, height: 80),
                                        normal: solidImage(width: 300, height: 80, red: 0.1),
                                        selected: solidImage(width: 300, height: 80, red: 0.9),
                                        activated: solidImage(width: 300, height: 80, red: 1),
                                        up: 0, down: 0, left: 0, right: 0, commands: [.jumpTitle(1)])],
            defaultButton: 0)
        var ac3 = [UInt8](repeating: 0, count: 768)
        ac3[0] = 0x0B; ac3[1] = 0x77; ac3[4] = 0x14
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("menu-\(UUID()).m2ts")
        defer { try? FileManager.default.removeItem(at: url) }
        let input = M2TSMuxer.Input(video: units, frameRate: .init(numerator: 24000, denominator: 1001),
                                    audio: Array(repeating: ac3, count: 63), menu: ig)
        let result = try M2TSMuxer.mux(input, to: url)
        let b = [UInt8](try Data(contentsOf: url))

        XCTAssertEqual(b.count % 6144, 0, "whole aligned units")
        XCTAssertEqual(result.sourcePackets, b.count / 192)
        XCTAssertEqual(result.endPTS - result.firstPTS, 180_180)    // 48 frames at 23.976
        var lastATS = -1
        var pids = Set<Int>()
        var pusiPackets = Set<Int>()
        for n in 0..<(b.count / 192) {
            let p = n * 192
            XCTAssertEqual(b[p + 4], 0x47)
            let ats = u32(b, p) & 0x3FFF_FFFF
            XCTAssertGreaterThan(ats, lastATS, "arrival times increase")
            lastATS = ats
            let pid = u16(b, p + 5) & 0x1FFF
            pids.insert(pid)
            if b[p + 5] & 0x40 != 0 && pid == TransportStreamPIDs.video { pusiPackets.insert(n) }
        }
        XCTAssertTrue(Set([0, 0x1F, 0x100, 0x1001, 0x1011, 0x1100, 0x1400]).isSubset(of: pids))
        XCTAssertTrue(pids.isSubset(of: [0, 0x1F, 0x100, 0x1001, 0x1011, 0x1100, 0x1400, 0x1FFF]))
        // PAT first, with a valid CRC.
        let pat = Array(b[9..<29])
        XCTAssertEqual(pat[0], 0)
        XCTAssertEqual(MPEGCRC32.checksum(pat[0..<16]), UInt32(u32(pat, 16)))
        // EP map: one entry per IDR, each at the start of a video PES.
        XCTAssertEqual(result.entryPoints.count, 2)
        for e in result.entryPoints { XCTAssertTrue(pusiPackets.contains(e.sourcePacket)) }
        XCTAssertEqual(result.entryPoints[0].pts, result.firstPTS)
    }

    func testJustInTimeMeetsDeadlines() {
        let times = M2TSMuxer.justInTime(counts: [3, 2], deadlines: [100_000, 101_000])
        XCTAssertEqual(times[1], [101_000 - 2030, 101_000])
        XCTAssertEqual(times[0].last!, 101_000 - 2 * 2030, "pushed back by the next frame's packets")
        XCTAssertEqual(times[0][1] - times[0][0], 2030)
    }

    func testPMTDescribesMenuStreams() {
        let ig = IGDisplaySet(segments: [])
        let input = M2TSMuxer.Input(video: [], frameRate: .init(numerator: 24000, denominator: 1001),
                                    audio: [[0x0B, 0x77]], menu: ig)
        let pmt = M2TSMuxer.pmtSection(input)
        XCTAssertEqual(pmt[0], 2)
        XCTAssertEqual(u16(pmt, 1) & 0xFFF, pmt.count - 3)
        XCTAssertEqual(MPEGCRC32.checksum(pmt[0..<(pmt.count - 4)]), UInt32(u32(pmt, pmt.count - 4)))
        XCTAssertEqual(u16(pmt, 8) & 0x1FFF, 0x1001, "PCR PID")
        let types = [0x1B, 0x81, 0x91]
        var at = 12 + (u16(pmt, 10) & 0xFFF)
        for t in types {
            XCTAssertEqual(Int(pmt[at]), t)
            at += 5 + (u16(pmt, at + 3) & 0xFFF)
        }
        XCTAssertEqual(at, pmt.count - 4)
    }
}

final class MenuNavigationTests: XCTestCase {
    private let film = PlaylistSummary(markCount: 3, subtitleStreams: 1, audioStreams: 1)

    func testDemoMenuNavigation() throws {
        let menu = MenuDemo.make(title: "Test", chapterTimes: [0, 20, 40], subtitles: true)
        XCTAssertEqual(menu.pages.map { $0.buttons.count }, [4, 4])
        let nav = try HDMVMenuAuthor.navigation(for: menu, film: film)

        XCTAssertEqual(nav.objects.count, 3)
        XCTAssertEqual(nav.index.firstPlayback, IndexTable.Entry(movieObject: 1, interactive: true))
        XCTAssertEqual(nav.index.topMenu, nav.index.firstPlayback)
        XCTAssertEqual(nav.index.titles, [IndexTable.Entry(movieObject: 0, interactive: false)])
        XCTAssertEqual(nav.objects[0].commands, [
            .setSubtitleStream(1, displayed: false), .ifEqual(register: 2, value: 1), .setSubtitleStream(1, displayed: true),
            .ifEqual(register: 0, value: 0), .goto(7), .playPlaylist(0, markInRegister: 0), .goto(8),
            .playPlaylist(0), .jumpObject(1)
        ])
        XCTAssertTrue(nav.objects[0].resumeIntention)
        XCTAssertEqual(nav.objects[1].commands, [.setButtonPage(button: 0, page: 0), .playPlaylist(1000), .goto(1)])
        XCTAssertEqual(nav.objects[2].commands, [.setButtonPage(button: 0, page: 0), .playPlaylist(1001), .goto(1)])

        XCTAssertEqual(nav.buttonCommands[0][0], [.move(register: 0, value: 0), .jumpTitle(1)])
        XCTAssertEqual(nav.buttonCommands[0][1], [.jumpObject(2)])
        XCTAssertEqual(nav.buttonCommands[0][2], [.move(register: 2, value: 1), .selectButton(2)])
        XCTAssertEqual(nav.buttonCommands[1][1], [.move(register: 0, value: 1), .jumpTitle(1)])
        XCTAssertEqual(nav.buttonCommands[1][3], [.jumpObject(1)])
        // Main page is a vertical list: up/down link neighbours, the ends stay put.
        XCTAssertEqual(nav.neighbours[0][0], [0, 1, 0, 0])
        XCTAssertEqual(nav.neighbours[0][3], [2, 3, 3, 3])
        // Scenes: right from chapter 1 is chapter 2, down is Back.
        XCTAssertEqual(nav.neighbours[1][0][3], 1)
        XCTAssertEqual(nav.neighbours[1][0][1], 3)
    }

    func testStillMenuDoesNotLoop() throws {
        var menu = MenuDemo.make(title: "T", chapterTimes: [0], subtitles: false)
        menu.loopSeconds = 0
        let noSubtitles = PlaylistSummary(markCount: 1, subtitleStreams: 0, audioStreams: 1)
        let nav = try HDMVMenuAuthor.navigation(for: menu, film: noSubtitles)
        XCTAssertEqual(nav.objects[1].commands, [.setButtonPage(button: 0, page: 0), .playPlaylist(1000)])
        XCTAssertEqual(nav.objects[0].commands.count, 6, "no subtitle commands")
    }

    func testRejectsBadMenus() {
        var menu = MenuDemo.make(title: "T", chapterTimes: [0, 20, 40, 60], subtitles: true)
        XCTAssertThrowsError(try HDMVMenuAuthor.navigation(for: menu, film: film)) { e in
            XCTAssertTrue(e.localizedDescription.contains("chapter 4"), e.localizedDescription)
        }
        menu = MenuDemo.make(title: "T", chapterTimes: [0], subtitles: true)
        XCTAssertThrowsError(try HDMVMenuAuthor.navigation(
            for: menu, film: PlaylistSummary(markCount: 1, subtitleStreams: 0, audioStreams: 1)))
        menu.pages[0].buttons[1].action = .goToPage(7)
        XCTAssertThrowsError(try HDMVMenuAuthor.navigation(for: menu, film: film))
        menu = MenuDemo.make(title: "T", chapterTimes: [0], subtitles: false)
        menu.pages[0].buttons[0].down = 9
        XCTAssertThrowsError(try HDMVMenuAuthor.navigation(for: menu, film: film))
        XCTAssertThrowsError(try HDMVMenuAuthor.navigation(for: DiscMenu(pages: []), film: film))
    }

    func testDemoScenePagesSplitAtEight() {
        let menu = MenuDemo.make(title: "T", chapterTimes: (0..<20).map { Double($0) * 300 }, subtitles: false)
        XCTAssertEqual(menu.pages.map { $0.buttons.count }, [2, 10, 10, 5])
        XCTAssertEqual(menu.pages[1].buttons.last?.action, .goToPage(2))
        XCTAssertEqual(menu.pages[3].buttons.last?.action, .goToPage(0))
        XCTAssertEqual(menu.pages[3].buttons[0].action, .playChapter(16))
    }
}

final class IGBudgetAndMapTests: XCTestCase {
    /// A smooth horizontal colour ramp: more colours than a palette holds,
    /// so a full palette gives short runs and a small one long runs.
    private func ramp(width: Int, height: Int, hue: Int) -> CGImage {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                px[i] = UInt8(x * 255 / (width - 1))
                px[i + 1] = UInt8(hue * 80)
                px[i + 2] = UInt8(255 - x * 255 / (width - 1))
            }
        }
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func rampButtons(_ n: Int, width: Int = 600, height: Int = 100, sameHue: Bool = false) -> [IGSEncoder.Button] {
        (0..<n).map { i in
            IGSEncoder.Button(rect: CGRect(x: 100, y: 100 + i * (height + 10), width: width, height: height),
                              normal: ramp(width: width, height: height, hue: 0),
                              selected: ramp(width: width, height: height, hue: sameHue ? 0 : 1),
                              activated: ramp(width: width, height: height, hue: sameHue ? 0 : 2),
                              up: i, down: i, left: i, right: i, commands: [])
        }
    }

    func testOversizedGraphicsDropToFewerColours() throws {
        let buttons = rampButtons(2)
        let full = try IGSEncoder.displaySet(buttons: buttons, defaultButton: nil, maxCodedBytes: .max)
        XCTAssertEqual(full.paletteSize, 255)
        let again = try IGSEncoder.displaySet(buttons: buttons, defaultButton: nil, maxCodedBytes: .max)
        XCTAssertEqual(again.segments.map(\.bytes), full.segments.map(\.bytes), "same images, same bytes")
        let limit = full.codedBytes - 1
        let reduced = try IGSEncoder.displaySet(buttons: buttons, defaultButton: nil, maxCodedBytes: limit)
        XCTAssertEqual(reduced.paletteSize, 127)
        XCTAssertLessThanOrEqual(reduced.codedBytes, limit)
    }

    func testGraphicsThatCantFitAreRefused() {
        XCTAssertThrowsError(try IGSEncoder.displaySet(buttons: rampButtons(1), defaultButton: nil, maxCodedBytes: 2000)) { e in
            guard case IGSEncoder.EncodeError.graphicsTooLarge(_, let limit) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(limit, 2000)
        }
    }

    func testDefaultBudgetIsTheCodedDataBuffer() throws {
        XCTAssertEqual(IGSEncoder.codedDataBufferBytes, 1_048_576)
        // Three wide ramp buttons: over 1 MiB at 255 colours (about 255
        // runs a row), so the default budget has to cut the palette.
        let buttons = rampButtons(3, width: 1700, height: 160, sameHue: true)
        let full = try IGSEncoder.displaySet(buttons: buttons, defaultButton: nil, maxCodedBytes: .max)
        XCTAssertGreaterThan(full.codedBytes, IGSEncoder.codedDataBufferBytes)
        let set = try IGSEncoder.displaySet(buttons: buttons, defaultButton: nil)
        XCTAssertLessThan(set.paletteSize, full.paletteSize)
        XCTAssertLessThanOrEqual(set.codedBytes, IGSEncoder.codedDataBufferBytes)
    }

    func testStateHashesMatchTheObjectsAsDrawn() throws {
        let set = try IGSEncoder.displaySet(buttons: rampButtons(1, width: 64, height: 16), defaultButton: 0)
        XCTAssertEqual(IGSEncoder.fnv1a(Array("a".utf8)), 0xE40C_292C)
        XCTAssertEqual(set.stateHashes.count, 1)
        // Decode each object's RLE the way a player does and hash it. Objects
        // 2 and 3 are the two frames of the activated state.
        let objects = set.segments.filter { $0.bytes[0] == 0x15 }
        XCTAssertEqual(objects.map { u16($0.bytes, 3) }, [0, 1, 2, 3])
        for (n, ods) in objects.enumerated() {
            let indices = RLE.decode(Array(ods.bytes[14...]), width: 64, height: 16)!
            XCTAssertEqual(IGSEncoder.fnv1a(indices), set.stateHashes[0][min(n, 2)])
        }
        XCTAssertEqual(Set(set.stateHashes[0]).count, 3, "the three states can be told apart")
    }

    func testMenuMapJSON() throws {
        typealias Map = HDMVMenuAuthor.MenuMap
        XCTAssertEqual(Map.action(.playChapter(4)), Map.Action(type: "playChapter", value: 4))
        XCTAssertEqual(Map.action(.setSubtitles(on: false)), Map.Action(type: "setSubtitles", value: 0))
        XCTAssertEqual(Map.action(.playFilm), Map.Action(type: "playFilm", value: nil))
        let map = Map(filmPlaylist: 0, firstPage: 0, loops: true, filmSubtitles: true, chapters: [0, 20.02],
                      pages: [Map.Page(playlist: 1000, defaultButton: 0, paletteSize: 12, graphicsBytes: 900,
                                       buttons: [Map.Button(id: 0, rect: [10, 20, 30, 40], up: nil, down: 1,
                                                            left: nil, right: nil, action: Map.action(.playFilm),
                                                            stateHashes: [1, 2, 4_000_000_000])])])
        let data = try map.json()
        XCTAssertEqual(try JSONDecoder().decode(Map.self, from: data), map)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"playlist\" : 1000"), text)
        XCTAssertFalse(text.contains("\"up\""), "nil neighbours are left out")
    }
}

final class UDFImageTests: XCTestCase {
    func testDString() {
        XCTAssertEqual(UDFImageWriter.dstring("BD", fieldLength: 6), [8, 0x42, 0x44, 0, 0, 3])
        XCTAssertEqual(UDFImageWriter.dstring("é", fieldLength: 4), [8, 0xE9, 0, 2])
        XCTAssertEqual(UDFImageWriter.dstring("映", fieldLength: 5), [16, 0x66, 0x20, 0, 3])
    }

    func testImageLayout() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("udf-\(UUID())")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("BDMV/STREAM"), withIntermediateDirectories: true)
        let payload = Data((0..<5000).map { UInt8($0 % 251) })
        try payload.write(to: dir.appendingPathComponent("BDMV/STREAM/00000.m2ts"))
        try Data("INDX0200".utf8).write(to: dir.appendingPathComponent("BDMV/index.bdmv"))
        let iso = dir.appendingPathComponent("out.iso")
        try UDFImageWriter.writeImage(of: dir.appendingPathComponent(""), to: iso, label: "TEST",
                                      header: .reproducible)
        let b = [UInt8](try Data(contentsOf: iso))
        func le16(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
        func le32(_ at: Int) -> Int { le16(at) | le16(at + 2) << 16 }
        func tagIsValid(_ at: Int) -> Bool {
            var sum: UInt8 = 0
            for i in 0..<16 where i != 4 { sum &+= b[at + i] }
            return sum == b[at + 4]
        }
        XCTAssertEqual(b.count % 2048, 0)
        XCTAssertEqual(Array(b[(17 * 2048 + 1)..<(17 * 2048 + 6)]), Array("NSR03".utf8))
        // Anchors at sector 256 and in the last sector, pointing at the
        // main volume descriptor sequence at sector 32.
        for anchor in [256 * 2048, b.count - 2048] {
            XCTAssertEqual(le16(anchor), 2)
            XCTAssertTrue(tagIsValid(anchor))
            XCTAssertEqual(le32(anchor + 20), 32)
        }
        XCTAssertEqual(le16(32 * 2048), 1, "primary volume descriptor")
        XCTAssertEqual(Array(b[(32 * 2048 + 24)..<(32 * 2048 + 29)]), [8] + Array("TEST".utf8))
        XCTAssertEqual(le16(320 * 2048), 256, "file set descriptor opens the metadata partition")
        XCTAssertEqual(le16(64 * 2048 + 0x88), 0x0250, "minimum UDF read revision 2.50")
        // The stream's bytes are in the image, sector-aligned.
        let needle = Array(payload.prefix(64))
        let found = stride(from: 0, to: b.count - 64, by: 2048).contains { Array(b[$0..<($0 + 64)]) == needle }
        XCTAssertTrue(found)
    }
}

final class ChapterAlignmentTests: XCTestCase {
    func testChaptersLandOnFrameStartsAndMarksRoundUp() {
        // Frame 959 starts at 39.99829 s: the mark rounds up to 39.999, not
        // down to 39.998 (before the frame, so players seek a GOP early).
        let t = VideoStandard.p1080_2398.frameStart(nearest: 40)
        XCTAssertEqual(t, 959 * 1001 / 24000, accuracy: 1e-9)
        XCTAssertEqual(BDMVAuthor.formatChapterTime(t), "00:00:39.999")
        XCTAssertEqual(BDMVAuthor.formatChapterTime(VideoStandard.p1080_2398.frameStart(nearest: 20)), "00:00:20.020")
        XCTAssertEqual(BDMVAuthor.formatChapterTime(20), "00:00:20.000")
        XCTAssertEqual(VideoStandard.p1080_24.frameStart(nearest: 300.01), 300)
        let args = BluRayEncoder.forcedKeyframeArguments([0, t], standard: .p1080_2398)
        XCTAssertEqual(args.first, "-force_key_frames")
        XCTAssertEqual(Double(args[1])!, t - 0.5 * 1001 / 24000, accuracy: 1e-4)
    }
}
