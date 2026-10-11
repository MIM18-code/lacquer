import Foundation

/// A single-clip playlist (BDMV/PLAYLIST/xxxxx.mpls).
struct Playlist: Equatable, Sendable {
    enum Still: Equatable, Sendable {
        case none
        /// Hold the last frame (and the menu on it) until the viewer acts.
        case infinite
    }

    /// Five-digit clip name, e.g. "01000" for STREAM/01000.m2ts.
    var clipName: String
    /// 45 kHz.
    var inTime: Int64
    var outTime: Int64
    var streams: [BDStream]
    var still: Still = .none
    /// 45 kHz times of chapter marks. Always at least `inTime`.
    var marks: [Int64]
}

/// Writes MPLS files following tsMuxeR's `MPLSParser::compose`, with an IG
/// entry added to the STN table. Read back by libbluray `mpls_parse.c`.
enum PlaylistWriter {
    static func data(_ pl: Playlist) -> Data {
        var w = ByteWriter()
        w.ascii("MPLS", length: 4)
        w.ascii("0200", length: 4)
        let playlistAddr = w.reserve(4)
        let markAddr = w.reserve(4)
        w.u32(0)                    // extension_data_start_address
        w.zeros(20)

        // AppInfoPlayList
        let appInfo = w.reserve(4)
        w.u8(0)
        w.u8(1)                     // playback type: sequential
        w.u16(0)
        w.zeros(8)                  // UO mask: nothing masked
        w.u16(0x4000)               // audio_mix_app_flag
        w.patchLength(at: appInfo, width: 4)
        w.align(to: 2)

        // PlayList
        w.patch(playlistAddr, width: 4, value: w.count)
        let playlist = w.reserve(4)
        w.u16(0)
        w.u16(1)                    // number_of_PlayItems
        w.u16(0)                    // number_of_SubPaths
        let item = w.reserve(2)
        w.ascii(pl.clipName, length: 5)
        w.ascii("M2TS", length: 4)
        w.u16(1)                    // not multi-angle, connection_condition 1
        w.u8(0)                     // ref_to_STC_id
        w.u32(Int(pl.inTime & 0xFFFF_FFFF))
        w.u32(Int(pl.outTime & 0xFFFF_FFFF))
        w.zeros(8)                  // UO mask
        w.u8(0)                     // PlayItem_random_access_flag, reserved
        switch pl.still {
        case .none:
            w.u8(0); w.u16(0)
        case .infinite:
            w.u8(2); w.u16(0)       // still_mode 2: infinite
        }
        writeSTN(&w, pl.streams)
        w.patchLength(at: item, width: 2)
        w.patchLength(at: playlist, width: 4)
        w.align(to: 2)

        // PlayListMark
        w.patch(markAddr, width: 4, value: w.count)
        let marks = w.reserve(4)
        w.u16(pl.marks.count)
        for t in pl.marks {
            w.u8(0)
            w.u8(1)                 // mark_type: entry mark (chapter)
            w.u16(0)                // PlayItem id
            w.u32(Int(t & 0xFFFF_FFFF))
            w.u16(0xFFFF)           // entry_ES_PID
            w.u32(0)                // duration
        }
        w.patchLength(at: marks, width: 4)
        return w.data
    }

    private static func writeSTN(_ w: inout ByteWriter, _ streams: [BDStream]) {
        func ofKind(_ match: (BDStream.Kind) -> Bool) -> [BDStream] { streams.filter { match($0.kind) } }
        let video = ofKind { if case .video = $0 { return true }; return false }
        let audio = ofKind { if case .audio = $0 { return true }; return false }
        let pg = ofKind { if case .subtitles = $0 { return true }; return false }
        let ig = ofKind { if case .menu = $0 { return true }; return false }

        let length = w.reserve(2)
        w.u16(0)
        w.u8(video.count); w.u8(audio.count); w.u8(pg.count); w.u8(ig.count)
        w.u8(0); w.u8(0); w.u8(0); w.u8(0)    // secondary audio/video, PiP PG, Dolby Vision
        w.u32(0)
        for s in video + audio + pg + ig {
            // stream_entry: type 1 = in the play item's own clip.
            w.u8(9); w.u8(1); w.u16(s.pid); w.zeros(6)
            let attr = w.reserve(1)
            w.u8(s.codingType)
            switch s.kind {
            case .video(let format, let rate, _):
                w.u8(format << 4 | rate); w.zeros(3)
            case .audio(let presentation, let sampling, let language):
                w.u8(presentation << 4 | sampling); w.ascii(language, length: 3)
            case .subtitles(let language), .menu(let language):
                w.ascii(language, length: 3); w.u8(0)
            }
            w.patchLength(at: attr, width: 1)
        }
        w.patchLength(at: length, width: 2)
    }
}

/// The few facts the menu author needs from the film playlist tsMuxeR wrote.
struct PlaylistSummary: Equatable {
    var markCount: Int
    var subtitleStreams: Int
    var audioStreams: Int

    enum ReadError: LocalizedError {
        case malformed(String)
        var errorDescription: String? {
            if case .malformed(let what) = self { return "The film playlist is malformed: \(what)." }
            return nil
        }
    }

    init(markCount: Int, subtitleStreams: Int, audioStreams: Int) {
        self.markCount = markCount
        self.subtitleStreams = subtitleStreams
        self.audioStreams = audioStreams
    }

    init(mpls: Data) throws {
        let b = [UInt8](mpls)
        func u16(_ at: Int) throws -> Int {
            guard at + 2 <= b.count else { throw ReadError.malformed("truncated at \(at)") }
            return Int(b[at]) << 8 | Int(b[at + 1])
        }
        func u32(_ at: Int) throws -> Int { try u16(at) << 16 | u16(at + 2) }
        guard b.count > 40, b.starts(with: Array("MPLS".utf8)) else { throw ReadError.malformed("no MPLS header") }
        let playlistStart = try u32(8)
        let markStart = try u32(12)
        guard try u16(playlistStart + 6) >= 1 else { throw ReadError.malformed("no play items") }
        // First PlayItem: length(2) name(5) codec(4) flags(2) stc(1) in(4)
        // out(4) UO(8) random/still(4) = 34 bytes before the STN table,
        // whose stream counts follow its length and 2 reserved bytes.
        let stn = playlistStart + 10 + 2 + 32
        audioStreams = Int(b[min(stn + 5, b.count - 1)])
        subtitleStreams = Int(b[min(stn + 6, b.count - 1)])
        markCount = try u16(markStart + 4)
    }
}
