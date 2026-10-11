import Foundation

/// PIDs as tsMuxeR and commercial discs assign them.
enum TransportStreamPIDs {
    static let pat = 0x0000
    static let sit = 0x001F
    static let pmt = 0x0100
    static let pcr = 0x1001
    static let video = 0x1011
    static let audio = 0x1100
    static let menu = 0x1400
    static let null = 0x1FFF
}

/// Writes a menu clip: a BD-ROM transport stream (192-byte source packets)
/// carrying H.264 video, optional AC-3 audio and an Interactive Graphics
/// stream. tsMuxeR can't carry IG (its graphics reader only labels streams
/// as PG), so menu clips are muxed here.
///
/// Timing model, all on the 27 MHz clock:
/// - The IG display set goes first at 16 Mbit/s, and its decode and
///   presentation times follow from when each segment has fully arrived.
/// - The first video frame is presented with the menu (ICS PTS).
/// - Video and audio arrive just in time at 20 Mbit/s, scheduled backwards
///   from each frame's decode time, so the decoder buffer holds no more
///   than the encoder's VBV allowed.
/// - PAT, PMT and a PCR go out every 70 ms, the SIT every 700 ms.
/// - Packets never go out faster than 45 Mbit/s, under the 48 Mbit/s limit.
/// - Each packet's arrival time stamp is the 27 MHz clock, so ATS and PCR
///   agree, as in tsMuxeR's output.
enum M2TSMuxer {
    struct AccessUnit: Sendable {
        var data: [UInt8]
        var isKeyframe: Bool
    }

    struct FrameRate: Equatable, Sendable {
        var numerator: Int
        var denominator: Int
        /// 90 kHz PTS of frame `k`, relative to frame 0.
        func pts(ofFrame k: Int) -> Int64 {
            Int64(k) * 90_000 * Int64(denominator) / Int64(numerator)
        }
    }

    struct Input {
        var video: [AccessUnit]
        var frameRate: FrameRate
        /// For the HDMV registration descriptor and the stream tables.
        var videoFormat: Int = 6
        var videoRate: Int = 1
        var videoAspect: Int = 3
        /// Whole AC-3 frames (1536 samples at 48 kHz). Empty for no audio.
        var audio: [[UInt8]] = []
        var audioBitrateKbps: Int = 192
        var menu: IGDisplaySet
    }

    struct Result: Equatable, Sendable {
        var sourcePackets: Int
        var entryPoints: [EntryPoint]
        /// 90 kHz PTS of the first frame and of the end of the last.
        var firstPTS: Int64
        var endPTS: Int64
    }

    enum MuxError: LocalizedError {
        case noVideo
        case deadlineMissed(String)
        case segmentTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .noVideo: return "The menu background encode produced no video frames."
            case .deadlineMissed(let what): return "Menu mux timing failed: \(what) arrives after its decode time."
            case .segmentTooLarge(let n): return "A menu graphics segment of \(n) bytes doesn't fit in one PES packet."
            }
        }
    }

    // MARK: - Timing constants (27 MHz ticks)

    static let clockStart: Int64 = 600 * 27_000_000
    static let systemSpacing: Int64 = 900        // 45 Mbit/s
    static let graphicsSpacing: Int64 = 2538     // 16 Mbit/s
    static let streamSpacing: Int64 = 2030       // 20 Mbit/s
    static let psiInterval: Int64 = 70 * 27_000  // 70 ms
    static let decodeMargin90k: Int64 = 900      // 10 ms
    static let graphicsMargin90k: Int64 = 450    // 5 ms
    static let ac3FrameTicks90k: Int64 = 2880    // 1536 samples at 48 kHz

    private enum Stream: Int { case menu = 0, audio = 1, video = 2 }

    /// A PES and the times (27 MHz) its TS packets should go out.
    private struct PES {
        var stream: Stream
        var pid: Int
        var bytes: [UInt8]
        var packetTimes: [Int64]
        /// 27 MHz: the last packet must arrive by then.
        var deadline: Int64
        var label: String
        var packetCount: Int { (bytes.count + 183) / 184 }
    }

    static func mux(_ input: Input, to url: URL) throws -> Result {
        guard !input.video.isEmpty else { throw MuxError.noVideo }

        // ---- IG display set: packet times, then timestamps.
        var menuSet = input.menu
        var graphicsTimes: [[Int64]] = []
        var t = clockStart + 4 * systemSpacing
        for seg in menuSet.segments {
            let pesLength = 9 + (seg.hasDTS ? 10 : 5) + seg.bytes.count
            guard pesLength - 6 <= 0xFFFF else { throw MuxError.segmentTooLarge(seg.bytes.count) }
            let n = (pesLength + 183) / 184
            graphicsTimes.append((0..<n).map { t + Int64($0) * graphicsSpacing })
            t += Int64(n) * graphicsSpacing
        }
        let arrivals90k = graphicsTimes.map { ($0.last! + 299) / 300 + graphicsMargin90k }
        var compositionPTS = menuSet.assignTimestamps(arrivals90k: arrivals90k)

        // ---- Video and audio, just in time before each decode time.
        let fps = input.frameRate
        func videoPES(_ au: AccessUnit, pts: Int64) -> [UInt8] {
            pesBytes(streamID: 0xE0, pts: pts, dts: nil, payload: au.data, bounded: false)
        }
        func audioPES(_ frame: [UInt8], pts: Int64) -> [UInt8] {
            pesBytes(streamID: 0xBD, pts: pts, dts: nil, payload: frame, bounded: true)
        }
        // Packet counts don't depend on the timestamp values.
        let videoCounts = input.video.map { (videoPES($0, pts: 0).count + 183) / 184 }
        let audioCounts = input.audio.map { (audioPES($0, pts: 0).count + 183) / 184 }

        var firstPTS = compositionPTS
        let earliest = clockStart + 4 * systemSpacing
        var videoTimes: [[Int64]] = []
        var audioTimes: [[Int64]] = []
        for _ in 0..<2 {
            videoTimes = justInTime(counts: videoCounts, deadlines: input.video.indices.map {
                (firstPTS + fps.pts(ofFrame: $0) - decodeMargin90k) * 300
            })
            audioTimes = justInTime(counts: audioCounts, deadlines: input.audio.indices.map {
                (firstPTS + Int64($0) * ac3FrameTicks90k - decodeMargin90k) * 300
            })
            let start = min(videoTimes.first?.first ?? earliest, audioTimes.first?.first ?? earliest)
            if start >= earliest { break }
            // Not enough lead time before the first frame: start everything later.
            firstPTS += (earliest - start + 299) / 300
        }
        if firstPTS != compositionPTS {
            compositionPTS = firstPTS
            menuSet.setCompositionPTS(firstPTS)
        }
        let endPTS = firstPTS + fps.pts(ofFrame: input.video.count)
        menuSet.setTimeouts(endPTS)

        // ---- Build the PES packets with final timestamps.
        var pesList: [PES] = []
        for (i, seg) in menuSet.segments.enumerated() {
            let bytes = pesBytes(streamID: 0xBD, pts: seg.pts, dts: seg.hasDTS ? seg.dts : nil,
                                 payload: seg.bytes, bounded: true)
            pesList.append(PES(stream: .menu, pid: TransportStreamPIDs.menu, bytes: bytes,
                               packetTimes: graphicsTimes[i], deadline: (seg.hasDTS ? seg.dts : seg.pts) * 300,
                               label: "menu segment \(i)"))
        }
        var videoPESIndex: [Int] = []
        for (k, au) in input.video.enumerated() {
            let pts = firstPTS + fps.pts(ofFrame: k)
            videoPESIndex.append(pesList.count)
            pesList.append(PES(stream: .video, pid: TransportStreamPIDs.video, bytes: videoPES(au, pts: pts),
                               packetTimes: videoTimes[k], deadline: pts * 300, label: "video frame \(k)"))
        }
        for (j, frame) in input.audio.enumerated() {
            let pts = firstPTS + Int64(j) * ac3FrameTicks90k
            pesList.append(PES(stream: .audio, pid: TransportStreamPIDs.audio, bytes: audioPES(frame, pts: pts),
                               packetTimes: audioTimes[j], deadline: pts * 300, label: "audio frame \(j)"))
        }

        // ---- Schedule every packet.
        enum Kind { case pat, pmt, sit, pcr, pes(Int, Int) }
        struct Slot { var time: Int64; var priority: Int; var seq: Int; var kind: Kind }
        var slots: [Slot] = []
        var seq = 0
        func add(_ time: Int64, _ priority: Int, _ kind: Kind) {
            slots.append(Slot(time: time, priority: priority, seq: seq, kind: kind)); seq += 1
        }
        let lastWanted = pesList.flatMap(\.packetTimes).max() ?? clockStart
        var psiTime = clockStart
        var psiIndex = 0
        while psiTime <= lastWanted + psiInterval {
            add(psiTime, 0, .pat)
            add(psiTime, 1, .pmt)
            if psiIndex % 10 == 0 { add(psiTime, 2, .sit) }
            add(psiTime, 3, .pcr)
            psiTime += psiInterval
            psiIndex += 1
        }
        for (p, pes) in pesList.enumerated() {
            for (i, time) in pes.packetTimes.enumerated() {
                add(time, 4 + pes.stream.rawValue, .pes(p, i))
            }
        }
        slots.sort { ($0.time, $0.priority, $0.seq) < ($1.time, $1.priority, $1.seq) }
        var previous = Int64.min
        for i in slots.indices {
            let actual = previous == .min ? slots[i].time : max(slots[i].time, previous + systemSpacing)
            slots[i].time = actual
            previous = actual
        }

        // ---- Check deadlines and find where each video frame starts.
        var lastArrival = [Int64](repeating: 0, count: pesList.count)
        var firstPacket = [Int](repeating: -1, count: pesList.count)
        for (n, slot) in slots.enumerated() {
            if case .pes(let p, _) = slot.kind {
                lastArrival[p] = max(lastArrival[p], slot.time)
                if firstPacket[p] < 0 { firstPacket[p] = n }
            }
        }
        for (p, pes) in pesList.enumerated() where lastArrival[p] > pes.deadline {
            throw MuxError.deadlineMissed(pes.label)
        }

        // ---- Write the packets.
        var out = [UInt8]()
        out.reserveCapacity((slots.count + 32) * 192)
        var continuity = [Int: Int]()
        func nextCC(_ pid: Int) -> Int {
            let c = continuity[pid, default: -1] + 1
            continuity[pid] = c & 0xF
            return c & 0xF
        }
        let pat = patSection()
        let pmt = pmtSection(input)
        for slot in slots {
            appendATS(&out, slot.time)
            switch slot.kind {
            case .pat: appendSection(&out, pid: TransportStreamPIDs.pat, section: pat, cc: nextCC(TransportStreamPIDs.pat))
            case .pmt: appendSection(&out, pid: TransportStreamPIDs.pmt, section: pmt, cc: nextCC(TransportStreamPIDs.pmt))
            case .sit:
                var sit = sitPacket
                sit[3] = 0x10 | UInt8(nextCC(TransportStreamPIDs.sit))
                out += sit
            case .pcr: appendPCR(&out, slot.time)
            case .pes(let p, let i):
                let pes = pesList[p]
                appendPESPacket(&out, pid: pes.pid, pes: pes.bytes, index: i, cc: nextCC(pes.pid))
            }
        }
        // Pad to whole aligned units (32 source packets, 6144 bytes).
        var padTime = (slots.last?.time ?? clockStart) + systemSpacing
        while (out.count / 192) % 32 != 0 {
            appendATS(&out, padTime)
            out += [0x47, 0x1F, 0xFF, 0x10] + [UInt8](repeating: 0xFF, count: 184)
            padTime += systemSpacing
        }
        try Data(out).write(to: url)

        let entries: [EntryPoint] = input.video.indices.compactMap { k in
            guard input.video[k].isKeyframe else { return nil }
            let p = videoPESIndex[k]
            return EntryPoint(pts: firstPTS + fps.pts(ofFrame: k),
                              sourcePacket: firstPacket[p],
                              byteLength: pesList[p].packetCount * 192)
        }
        return Result(sourcePackets: out.count / 192, entryPoints: entries,
                      firstPTS: firstPTS, endPTS: endPTS)
    }

    /// Latest packet times (27 MHz) that deliver each unit's packets at
    /// `streamSpacing` and finish by its deadline, scheduled from the last
    /// unit backwards.
    static func justInTime(counts: [Int], deadlines: [Int64]) -> [[Int64]] {
        var result = [[Int64]](repeating: [], count: counts.count)
        var nextStart = Int64.max
        for k in counts.indices.reversed() {
            let end = min(deadlines[k], nextStart == .max ? .max : nextStart - streamSpacing)
            let n = Int64(counts[k])
            result[k] = (0..<counts[k]).map { end - (n - 1 - Int64($0)) * streamSpacing }
            nextStart = result[k].first ?? end
        }
        return result
    }

    // MARK: - Packet builders

    static func pesBytes(streamID: UInt8, pts: Int64, dts: Int64?, payload: [UInt8], bounded: Bool) -> [UInt8] {
        let headerData = dts == nil ? 5 : 10
        var b: [UInt8] = [0, 0, 1, streamID]
        let length = bounded ? 3 + headerData + payload.count : 0
        b += [UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)]
        b += [0x84, dts == nil ? 0x80 : 0xC0, UInt8(headerData)]
        b += timestamp(pts, prefix: dts == nil ? 0x2 : 0x3)
        if let dts { b += timestamp(dts, prefix: 0x1) }
        return b + payload
    }

    static func timestamp(_ v: Int64, prefix: UInt8) -> [UInt8] {
        let v = UInt64(bitPattern: v) & 0x1_FFFF_FFFF
        return [
            prefix << 4 | UInt8((v >> 29) & 0x0E) | 1,
            UInt8((v >> 22) & 0xFF),
            UInt8((v >> 14) & 0xFE) | 1,
            UInt8((v >> 7) & 0xFF),
            UInt8((v << 1) & 0xFE) | 1
        ]
    }

    private static func appendATS(_ out: inout [UInt8], _ time: Int64) {
        let ats = UInt32(truncatingIfNeeded: time) & 0x3FFF_FFFF
        out += [UInt8(ats >> 24), UInt8((ats >> 16) & 0xFF), UInt8((ats >> 8) & 0xFF), UInt8(ats & 0xFF)]
    }

    private static func appendPESPacket(_ out: inout [UInt8], pid: Int, pes: [UInt8], index: Int, cc: Int) {
        let start = index * 184
        let chunk = pes[start..<min(start + 184, pes.count)]
        let first = index == 0
        out += [0x47, (first ? 0x40 : 0) | UInt8(pid >> 8), UInt8(pid & 0xFF)]
        if chunk.count == 184 {
            out.append(0x10 | UInt8(cc))
        } else {
            // Short last packet: pad with adaptation-field stuffing, since
            // the PES length must match the payload exactly.
            out.append(0x30 | UInt8(cc))
            let fieldLength = 183 - chunk.count
            out.append(UInt8(fieldLength))
            if fieldLength > 0 {
                out.append(0x00)
                out += [UInt8](repeating: 0xFF, count: fieldLength - 1)
            }
        }
        out += chunk
    }

    private static func appendPCR(_ out: inout [UInt8], _ time: Int64) {
        let base = time / 300, ext = time % 300
        let pid = TransportStreamPIDs.pcr
        // Adaptation field only, so the continuity counter doesn't advance.
        out += [0x47, UInt8(pid >> 8), UInt8(pid & 0xFF), 0x20, 183, 0x10]
        out += [UInt8((base >> 25) & 0xFF), UInt8((base >> 17) & 0xFF), UInt8((base >> 9) & 0xFF),
                UInt8((base >> 1) & 0xFF), UInt8(((base & 1) << 7) | 0x7E | (ext >> 8)), UInt8(ext & 0xFF)]
        out += [UInt8](repeating: 0xFF, count: 176)
    }

    private static func appendSection(_ out: inout [UInt8], pid: Int, section: [UInt8], cc: Int) {
        out += [0x47, 0x40 | UInt8(pid >> 8), UInt8(pid & 0xFF), 0x10 | UInt8(cc), 0x00]
        out += section
        out += [UInt8](repeating: 0xFF, count: 184 - 1 - section.count)
    }

    /// Program 0 points at the SIT (as tsMuxeR does), program 1 at the PMT.
    static func patSection() -> [UInt8] {
        var w = ByteWriter()
        w.u8(0x00)
        let length = w.reserve(2)
        w.u16(0)                        // transport_stream_id
        w.u8(0xC1); w.u8(0); w.u8(0)    // version 0, current; section 0 of 0
        w.u16(0); w.u16(0xE000 | TransportStreamPIDs.sit)
        w.u16(1); w.u16(0xE000 | TransportStreamPIDs.pmt)
        return finishSection(w, lengthAt: length)
    }

    static func pmtSection(_ input: Input) -> [UInt8] {
        var w = ByteWriter()
        w.u8(0x02)
        let length = w.reserve(2)
        w.u16(1)                        // program_number
        w.u8(0xC1); w.u8(0); w.u8(0)
        w.u16(0xE000 | TransportStreamPIDs.pcr)
        // HDMV registration and copy-control descriptors, as tsMuxeR writes.
        let program: [UInt8] = [0x05, 0x04] + Array("HDMV".utf8) + [0x88, 0x04, 0x0F, 0xFF, 0xFC, 0xFC]
        w.u16(0xF000 | program.count)
        w.append(program)

        let videoDescriptor: [UInt8] = [0x05, 0x08] + Array("HDMV".utf8)
            + [0xFF, 0x1B, UInt8(input.videoFormat << 4 | input.videoRate), UInt8(input.videoAspect << 4 | 0x0F)]
        writeStream(&w, type: 0x1B, pid: TransportStreamPIDs.video, info: videoDescriptor)
        if !input.audio.isEmpty {
            let rateCode = ac3RateCode(kbps: input.audioBitrateKbps)
            let audioDescriptor: [UInt8] = [0x05, 0x04] + Array("AC-3".utf8)
                + [0x81, 0x04, 0x08, UInt8(rateCode << 2), 0x04, 0x00]
            writeStream(&w, type: 0x81, pid: TransportStreamPIDs.audio, info: audioDescriptor)
        }
        writeStream(&w, type: 0x91, pid: TransportStreamPIDs.menu, info: [])
        return finishSection(w, lengthAt: length)
    }

    private static func writeStream(_ w: inout ByteWriter, type: Int, pid: Int, info: [UInt8]) {
        w.u8(type)
        w.u16(0xE000 | pid)
        w.u16(0xF000 | info.count)
        w.append(info)
    }

    private static func finishSection(_ w: ByteWriter, lengthAt: Int) -> [UInt8] {
        var w = w
        // section_length counts everything after it, CRC included.
        w.patch(lengthAt, width: 2, value: 0xB000 | (w.count - lengthAt - 2 + 4))
        let crc = MPEGCRC32.checksum(w.bytes[...])
        w.u32(Int(crc))
        return w.bytes
    }

    static func ac3RateCode(kbps: Int) -> Int {
        let rates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]
        return rates.firstIndex(of: kbps) ?? 10
    }

    /// tsMuxeR's Selection Information Table packet (48 Mbit/s peak rate).
    static let sitPacket: [UInt8] = [
        0x47, 0x40, 0x1F, 0x10, 0x00, 0x7F, 0xF0, 0x19, 0xFF, 0xFF, 0xC1, 0x00, 0x00, 0xF0, 0x0A, 0x63, 0x08, 0xC1, 0xD4,
        0xC0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01, 0x80, 0x00, 0x03, 0x00, 0x38, 0x6D
    ] + [UInt8](repeating: 0xFF, count: 155)

    // MARK: - Elementary stream parsing

    /// Splits an Annex B H.264 stream into access units at each access
    /// unit delimiter (x264 writes one per frame with `aud=1`). An access
    /// unit holding an IDR slice is a keyframe.
    static func accessUnits(h264 data: Data) -> [AccessUnit] {
        let b = [UInt8](data)
        var starts: [(offset: Int, type: Int)] = []
        var i = 0
        while i + 3 < b.count {
            if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
                let offset = (i > 0 && b[i - 1] == 0) ? i - 1 : i
                starts.append((offset, Int(b[i + 3] & 0x1F)))
                i += 3
            } else {
                i += 1
            }
        }
        var units: [AccessUnit] = []
        var current: (start: Int, key: Bool)?
        for s in starts {
            if s.type == 9 {
                if let c = current { units.append(AccessUnit(data: Array(b[c.start..<s.offset]), isKeyframe: c.key)) }
                current = (s.offset, false)
            } else if s.type == 5 {
                current?.key = true
            }
        }
        if let c = current { units.append(AccessUnit(data: Array(b[c.start...]), isKeyframe: c.key)) }
        return units
    }

    /// Splits a raw AC-3 stream into frames using each frame's size code.
    static func ac3Frames(_ data: Data) -> [[UInt8]] {
        let b = [UInt8](data)
        let kbps = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]
        var frames: [[UInt8]] = []
        var i = 0
        while i + 5 <= b.count, b[i] == 0x0B, b[i + 1] == 0x77 {
            let fscod = b[i + 4] >> 6
            let code = Int(b[i + 4] & 0x3F) >> 1
            guard fscod == 0, code < kbps.count else { break }   // 48 kHz only
            let size = kbps[code] * 4                           // 2 * kbps 16-bit words
            guard i + size <= b.count else { break }
            frames.append(Array(b[i..<i + size]))
            i += size
        }
        return frames
    }
}
