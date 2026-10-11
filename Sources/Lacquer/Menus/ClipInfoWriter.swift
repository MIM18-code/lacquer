import Foundation

/// An elementary stream as a clip's ProgramInfo and a playlist's STN table
/// describe it.
struct BDStream: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// H.264 (coding type 0x1B). format 6 = 1080p, rate 1 = 23.976,
        /// aspect 3 = 16:9.
        case video(format: Int, rate: Int, aspect: Int)
        /// AC-3 (0x81). presentation 3 = stereo, sampling 1 = 48 kHz.
        case audio(presentation: Int, sampling: Int, language: String)
        /// Presentation Graphics, i.e. subtitles (0x90).
        case subtitles(language: String)
        /// Interactive Graphics, the menu (0x91).
        case menu(language: String)
    }

    var pid: Int
    var kind: Kind

    var codingType: Int {
        switch kind {
        case .video: return 0x1B
        case .audio: return 0x81
        case .subtitles: return 0x90
        case .menu: return 0x91
        }
    }
}

/// One EP_map entry: where a player can start decoding (an I frame).
struct EntryPoint: Equatable, Sendable {
    /// 90 kHz PTS of the I frame.
    var pts: Int64
    /// Index of the source packet that starts the frame's PES.
    var sourcePacket: Int
    /// Bytes of source packets carrying the frame, for I_end_position_offset.
    var byteLength: Int
}

struct ClipInfo: Equatable, Sendable {
    var sourcePacketCount: Int
    /// Bytes per second; 6,000,000 is the 48 Mbit/s BD-ROM maximum.
    var tsRecordingRate: Int = 6_000_000
    var pcrPID: Int
    /// 45 kHz, the first frame's PTS / 2.
    var presentationStart: Int64
    /// 45 kHz, end of the last frame / 2.
    var presentationEnd: Int64
    var streams: [BDStream]
    var entryPointPID: Int
    var entryPoints: [EntryPoint]
}

/// Writes BDMV/CLIPINF/xxxxx.clpi. The layout follows tsMuxeR's
/// `CLPIParser::compose` (the clips it writes play on hardware) and is read
/// back by libbluray `clpi_parse.c`.
enum ClipInfoWriter {
    static func data(_ clip: ClipInfo) -> Data {
        var w = ByteWriter()
        w.ascii("HDMV", length: 4)
        w.ascii("0200", length: 4)
        let sequenceAddr = w.reserve(4)
        let programAddr = w.reserve(4)
        let cpiAddr = w.reserve(4)
        let clipMarkAddr = w.reserve(4)
        w.u32(0)            // extension_data_start_address: none
        w.zeros(12)         // reserved, ClipInfo starts at byte 40

        // ClipInfo
        let clipInfoLength = w.reserve(4)
        w.u16(0)
        w.u8(1)             // clip_stream_type: AV stream
        w.u8(1)             // application_type: main TS of a movie playlist
        w.u32(0)            // reserved, is_ATC_delta = 0
        w.u32(clip.tsRecordingRate)
        w.u32(clip.sourcePacketCount)
        w.zeros(128)
        // TS_type_info_block
        let typeInfoLength = w.reserve(2)
        w.u8(0x80)          // validity flags
        w.ascii("HDMV", length: 4)
        w.zeros(9 + 16)     // network information, stream format name
        w.patchLength(at: typeInfoLength, width: 2)
        w.patchLength(at: clipInfoLength, width: 4)
        w.align(to: 4)

        // SequenceInfo: one ATC sequence holding one STC sequence.
        w.patch(sequenceAddr, width: 4, value: w.count)
        let sequenceLength = w.reserve(4)
        w.u8(0)
        w.u8(1)             // number_of_ATC_sequences
        w.u32(0)            // SPN_ATC_start
        w.u8(1)             // number_of_STC_sequences
        w.u8(0)             // offset_STC_id
        w.u16(clip.pcrPID)
        w.u32(0)            // SPN_STC_start
        w.u32(Int(clip.presentationStart & 0xFFFF_FFFF))
        w.u32(Int(clip.presentationEnd & 0xFFFF_FFFF))
        w.patchLength(at: sequenceLength, width: 4)
        w.align(to: 4)

        // ProgramInfo: one program sequence with every stream.
        w.patch(programAddr, width: 4, value: w.count)
        let programLength = w.reserve(4)
        w.u8(0)
        w.u8(1)             // number_of_program_sequences
        w.u32(0)            // SPN_program_sequence_start
        w.u16(TransportStreamPIDs.pmt)
        w.u8(clip.streams.count)
        w.u8(0)             // number_of_groups
        for stream in clip.streams {
            w.u16(stream.pid)
            writeCodingInfo(&w, stream)
        }
        w.patchLength(at: programLength, width: 4)
        w.align(to: 4)

        // CPI: the EP_map.
        w.patch(cpiAddr, width: 4, value: w.count)
        let cpiLength = w.reserve(4)
        w.u16(1)            // 12 reserved bits, CPI_type 1 (EP_map)
        writeEPMap(&w, pid: clip.entryPointPID, entries: clip.entryPoints)
        w.patchLength(at: cpiLength, width: 4)
        w.align(to: 4)

        // ClipMark: empty.
        w.patch(clipMarkAddr, width: 4, value: w.count)
        w.u32(0)
        return w.data
    }

    /// StreamCodingInfo, 21 bytes after its length byte for every kind.
    private static func writeCodingInfo(_ w: inout ByteWriter, _ s: BDStream) {
        let length = w.reserve(1)
        w.u8(s.codingType)
        switch s.kind {
        case .video(let format, let rate, let aspect):
            w.u8(format << 4 | rate)
            w.u8(aspect << 4)    // 2 reserved bits, cc_flag 0, reserved
            w.u16(0)             // no HDR
            writeISRC(&w)
        case .audio(let presentation, let sampling, let language):
            w.u8(presentation << 4 | sampling)
            w.ascii(language, length: 3)
            writeISRC(&w)
        case .subtitles(let language), .menu(let language):
            w.ascii(language, length: 3)
            w.u8(0)
            writeISRC(&w)
        }
        w.patchLength(at: length, width: 1)
    }

    private static func writeISRC(_ w: inout ByteWriter) {
        w.ascii("", length: 12)  // "000000000000", as tsMuxeR writes
        w.u32(0)
    }

    /// EP_map for one PID: coarse entries every time the PTS bits above 19
    /// or the packet number bits above 17 change, fine entries for every
    /// I frame. Same grouping as tsMuxeR `buildCoarseInfo`.
    private static func writeEPMap(_ w: inout ByteWriter, pid: Int, entries: [EntryPoint]) {
        let mapStart = w.count
        struct Coarse { var fineIndex: Int; var pts: Int; var spn: Int }
        var coarse: [Coarse] = []
        var lastCoarsePTS = -1
        var lastCoarseSPN = -1
        for (i, e) in entries.enumerated() {
            let cpts = Int((e.pts >> 19) & 0x3FFF)
            let cspn = e.sourcePacket & ~0x1FFFF
            if coarse.isEmpty || cpts != lastCoarsePTS || cspn != lastCoarseSPN {
                coarse.append(Coarse(fineIndex: i, pts: cpts, spn: e.sourcePacket))
            }
            lastCoarsePTS = cpts
            lastCoarseSPN = cspn
        }

        w.u8(0)
        w.u8(1)                 // number_of_stream_PID_entries
        w.u16(pid)
        // 10 reserved bits, EP_stream_type 1 (video), 16-bit coarse count,
        // 18-bit fine count: 48 bits.
        let packed = (UInt64(1) << 34) | (UInt64(coarse.count) << 18) | UInt64(entries.count)
        for shift in stride(from: 40, through: 0, by: -8) { w.u8(Int((packed >> UInt64(shift)) & 0xFF)) }
        let streamAddr = w.reserve(4)
        w.align(to: 2)

        let streamStart = w.count
        w.patch(streamAddr, width: 4, value: streamStart - mapStart)
        let fineAddr = w.reserve(4)
        for c in coarse {
            w.u32((c.fineIndex << 14) | c.pts)
            w.u32(c.spn)
        }
        w.align(to: 2)
        w.patch(fineAddr, width: 4, value: w.count - streamStart)
        for e in entries {
            let endCode = Self.endPositionCode(bytes: e.byteLength)
            let fine = (endCode << 28) | (Int((e.pts >> 9) & 0x7FF) << 17) | (e.sourcePacket & 0x1FFFF)
            w.u32(fine)
        }
    }

    /// I_end_position_offset: how far the I frame extends, in tsMuxeR's
    /// size classes for HD video.
    static func endPositionCode(bytes: Int) -> Int {
        switch bytes {
        case ..<1: return 0
        case ..<131_072: return 1
        case ..<262_144: return 2
        case ..<393_216: return 3
        case ..<589_824: return 4
        case ..<917_504: return 5
        case ..<1_310_720: return 6
        default: return 7
        }
    }
}
