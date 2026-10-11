import Foundation

/// Video and audio encoding with Blu-ray-compliant parameters.
struct BluRayEncoder {
    let ffmpeg: URL

    // MARK: - Bitrate math

    /// Blu-ray H.264 max is 40 Mbps total A/V; leave headroom under 35 Mbps
    /// for video so audio + mux overhead never push us past spec.
    static let videoBitrateCeiling = 34_500_000

    /// Recommended quality floor for 1080p Blu-ray content. Picture quality
    /// visibly degrades below this rate. Not a hard limit — long titles may
    /// fall below it to fit the disc, in which case the coordinator surfaces
    /// a warning. 720p content tolerates lower bitrates but we use the same
    /// threshold for the warning to err on the side of flagging.
    static let videoBitrateQualityFloor = 8_000_000

    /// Encoder-sane absolute minimum. libx264 will accept lower values but
    /// the picture becomes unwatchable. If the disc-fit math wants a value
    /// even lower than this, the duration × disc-size × audio-rate combo is
    /// physically impossible — the coordinator detects this and fails the
    /// job with a useful error rather than silently producing oversized
    /// output (the previous bug: an 8 Mbps "floor" forced the math to lie
    /// when long titles couldn't actually fit at that rate).
    static let videoBitrateAbsoluteFloor = 1_000_000

    /// Target video bitrate (bps) so the encode fits the disc, capped at the
    /// Blu-ray H.264 ceiling. NOTE: the result is also clamped at a 1 Mbps
    /// absolute floor so libx264 always has a workable target. The caller
    /// should check `fitsOnDisc(...)` separately to detect the case where
    /// the title is too long to fit on the selected disc — in that case the
    /// returned bitrate alone will not actually fit the encode.
    static func videoBitrate(
        durationSeconds: Double,
        discBytes: Int64,
        audioBitsPerSecond: Int
    ) -> Int {
        guard durationSeconds > 0 else { return 15_000_000 }
        let totalBits = Double(discBytes) * 8
        let audioBits = Double(audioBitsPerSecond) * durationSeconds
        let usable = max(totalBits - audioBits, 0)
        let bps = usable / durationSeconds
        return max(videoBitrateAbsoluteFloor,
                   min(videoBitrateCeiling, Int(bps)))
    }

    /// True when the requested bitrate actually fits on the disc with the
    /// requested audio for the given duration. Use this AFTER `videoBitrate`
    /// to catch the case where the math's hard floor (1 Mbps) is higher
    /// than the disc-fit value would naturally be, i.e. the title is
    /// physically too long to fit at any usable encode quality.
    static func fitsOnDisc(
        videoBitrate: Int,
        durationSeconds: Double,
        discBytes: Int64,
        audioBitsPerSecond: Int
    ) -> Bool {
        guard durationSeconds > 0 else { return true }
        let totalBits = Double(discBytes) * 8
        let plannedBits = Double(videoBitrate) * durationSeconds
            + Double(audioBitsPerSecond) * durationSeconds
        return plannedBits <= totalBits
    }

    // MARK: - Video

    func encodeVideo(
        input: URL,
        videoOut: URL,
        bitrate: Int,
        standard: VideoStandard,
        sourceIsInterlaced: Bool,
        sourceFrameRate: Double,
        twoPass: Bool,
        duration: Double,
        logger: RunLogger? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Build x264 params.
        var params: [String] = [
            "bluray-compat=1",
            "level=\(standard.h264Level)",
            "keyint=\(standard.keyint)",
            "min-keyint=\(standard.keyint)",
            "bframes=3",
            "b-pyramid=strict",
            "weightp=0",
            "weightb=1",
            "ref=3",
            "aud=1",
            "nal-hrd=vbr",
            "colorprim=bt709",
            "transfer=bt709",
            "colormatrix=bt709",
            "slices=4"
        ]
        if standard.isInterlaced {
            // x264 / libx264 in ffmpeg accepts `tff=1` (or `bff=1`), NOT
            // `interlaced=tff`. The latter is rejected at parse time
            // ("Error parsing option 'interlaced = tff'"); ffmpeg then
            // continues with progressive defaults and 1080i presets
            // silently produce a progressive H.264 stream that ffprobe
            // reports as `field_order=progressive`. Verified: `tff=1`
            // yields `field_order=tt` (top-field-first) on the bundled
            // libx264.
            params.append("tff=1")
        }
        let x264Joined = params.joined(separator: ":")

        // Build the video filter chain.
        //
        // Order matters. The chain is built as:
        //
        //   [bwdif?] → scale → pad → setsar → [interlace|setfield?] → format
        //
        // The deinterlacer comes BEFORE the scaler. If `bwdif` ran after
        // `scale`, the scaler would see combed interlaced frames as
        // progressive and blend the two fields together (especially
        // visible on 1080i → 720p downscales) before the deinterlacer
        // ever got a clean shot at separating them.
        //
        // `force_original_aspect_ratio=decrease` shrinks the source to fit
        // *inside* the BD frame without stretching, then `pad` adds black
        // bars to reach the exact target dimensions. This letterboxes
        // 2.39:1 / DCI / 1.85:1 / 21:9 sources and pillarboxes 4:3 sources
        // instead of geometrically distorting them. For 16:9 sources the
        // pad is a no-op.
        let w = standard.width
        let h = standard.height
        var vf = ""
        if !standard.isInterlaced && sourceIsInterlaced {
            // Interlaced → progressive needs an actual deinterlacer, or the
            // encoder happily compresses combed fields as if they were
            // progressive frames and the result has visible interlace
            // artefacts. `bwdif` is the modern motion-adaptive deinterlacer
            // (better than `yadif`) and is in every ffmpeg build we ship.
            //
            // Mode picks based on whether the target frame rate is roughly
            // double the source's interlaced frame rate:
            //
            // - `send_field` emits one progressive frame per *field*
            //   (1080i29.97 → 720p59.94: 29.97 frames × 2 fields = 59.94 fps).
            //   Preserves the full temporal motion of the source — every
            //   field becomes a unique output frame, no duplication.
            // - `send_frame` emits one progressive frame per *frame*
            //   (everything else: 1080i25 → 1080p23.976, 1080i29.97 →
            //   720p23.976, etc.). Halves the temporal information of the
            //   source, which is the right call when the target rate is
            //   ≤ source frame rate; ffmpeg's `-r` then handles any
            //   remaining rate retiming.
            //
            // `parity=auto` lets ffmpeg pick from the source's field order
            // tag. We assume TFF when the tag is absent — virtually all
            // 1080i/29.97 and 1080i/25 broadcast material is TFF.
            //
            // Tolerance of 0.05 around 2.0 catches 59.94/29.97 (=2.000)
            // and 50/25 (=2.000); excludes anything else.
            let targetFps = standard.frameRateValue
            let ratio = sourceFrameRate > 0 ? targetFps / sourceFrameRate : 0
            let mode = abs(ratio - 2.0) < 0.05 ? "send_field" : "send_frame"
            vf += "bwdif=mode=\(mode):parity=auto:deint=all,"
        }
        vf += "scale=\(w):\(h):flags=lanczos:force_original_aspect_ratio=decrease,"
            + "pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1/1"
        if standard.isInterlaced && !sourceIsInterlaced {
            // Progressive → interlaced needs two different paths depending
            // on source rate.
            //
            // 1. Source fps ≈ 2× target frame rate (50p → 25i, 59.94p →
            //    29.97i): use `interlace=scan=tff` to pair adjacent frames
            //    into top/bottom fields. Halves frame rate, keeps field
            //    rate intact. SAFE only when the ratio is genuinely near
            //    2.0 — cross-standard cases like 50p → 29.97i have ratio
            //    ≈ 1.67, where pairing yields 25 fps and `-r` then
            //    duplicates back to 29.97, causing stutter.
            // 2. Anything else (same-rate 25p → 25i, 29.97p → 29.97i;
            //    cross-standard 50p → 29.97i; slow sources like 23.976 →
            //    29.97i): `setfield=mode=tff` flags each frame as PsF
            //    (Progressive Segmented Frame). x264's `tff=1` +
            //    `+ildct+ilme` encode it as a pair of fields without
            //    changing the cadence. ffmpeg's `-r` then handles the
            //    rate retiming via duplication, which is suboptimal for
            //    cross-standard but at least avoids the field-pair
            //    stutter the `interlace` filter would introduce.
            //
            // Tolerance of 0.05 around 2.0 covers 50/25 (=2.000) and
            // 59.94/29.97 (=2.000) and 60/29.97 (=2.002), but excludes
            // 50/29.97 (=1.668) and 59.94/25 (=2.398).
            let targetFps = standard.frameRateValue
            let ratio = targetFps > 0 ? sourceFrameRate / targetFps : 0
            if abs(ratio - 2.0) < 0.05 {
                vf += ",interlace=scan=tff:lowpass=0"
            } else {
                vf += ",setfield=mode=tff"
            }
        }
        vf += ",format=yuv420p"

        let bitrateK = "\(bitrate / 1000)k"

        func baseArgs(pass: Int?, passlog: URL?) -> [String] {
            var args: [String] = [
                "-y",
                "-i", input.path,
                "-an", "-sn",
                "-vf", vf,
                "-r", standard.frameRate,
                "-c:v", "libx264",
                "-preset", "slow",
                "-profile:v", "high",
                "-level:v", standard.h264Level,
                "-pix_fmt", "yuv420p",
                "-color_primaries", "bt709",
                "-color_trc", "bt709",
                "-colorspace", "bt709",
                "-b:v", bitrateK,
                "-maxrate", "35000k",
                "-bufsize", "30000k",
                "-x264-params", x264Joined,
                "-f", "h264",
                "-progress", "pipe:1",
                "-nostats"
            ]
            if standard.isInterlaced {
                args += ["-flags", "+ildct+ilme", "-top", "1"]
            }
            if let p = pass, let log = passlog {
                args += ["-pass", "\(p)", "-passlogfile", log.path]
            }
            return args
        }

        if twoPass {
            let passlog = FileManager.default.temporaryDirectory
                .appendingPathComponent("bdcomp-\(UUID().uuidString)")

            // Cleanup must run regardless of which pass throws — otherwise
            // a pass-1 failure leaves the libx264 stats files behind in
            // /tmp indefinitely. The suffixes below are the exact names
            // libx264 writes (`<base>-0.log` and `<base>-0.log.mbtree`).
            defer {
                let base = passlog.path
                for suffix in ["-0.log", "-0.log.mbtree"] {
                    try? FileManager.default.removeItem(atPath: base + suffix)
                }
            }

            var p1 = baseArgs(pass: 1, passlog: passlog)
            p1.append("/dev/null")
            try await runFFmpeg(args: p1, duration: duration, logger: logger,
                                subprocessName: "ffmpeg video pass 1") { frac in
                progress(frac * 0.5)
            }

            var p2 = baseArgs(pass: 2, passlog: passlog)
            p2.append(videoOut.path)
            try await runFFmpeg(args: p2, duration: duration, logger: logger,
                                subprocessName: "ffmpeg video pass 2") { frac in
                progress(0.5 + frac * 0.5)
            }
        } else {
            var args = baseArgs(pass: nil, passlog: nil)
            args.append(videoOut.path)
            try await runFFmpeg(args: args, duration: duration, logger: logger,
                                subprocessName: "ffmpeg video", progress: progress)
        }
    }

    // MARK: - Audio

    /// AC-3 at the requested bitrate, encoded from a specific source audio
    /// stream by ffmpeg index. Channel count is clamped to 6 (AC-3's 5.1
    /// ceiling); 7.1 or 5.1+Lt/Rt sources are downmixed using ffmpeg's
    /// standard matrix, which folds Lss/Rss (or matrix Lt/Rt) back into
    /// Ls/Rs. Stereo and mono sources are preserved at their native count.
    func encodeAudio(
        input: URL,
        audioOut: URL,
        bitrateKbps: Int,
        sourceStreamIndex: Int,
        sourceChannels: Int,
        duration: Double,
        logger: RunLogger? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let channels = min(max(sourceChannels, 1), 6)
        let args: [String] = [
            "-y",
            "-i", input.path,
            "-map", "0:\(sourceStreamIndex)",
            "-vn", "-sn",
            "-c:a", "ac3",
            "-b:a", "\(bitrateKbps)k",
            "-ac", "\(channels)",
            "-ar", "48000",
            "-progress", "pipe:1",
            "-nostats",
            audioOut.path
        ]
        try await runFFmpeg(args: args, duration: duration, logger: logger,
                            subprocessName: "ffmpeg audio", progress: progress)
    }

    // MARK: - Helper

    private func runFFmpeg(
        args: [String],
        duration: Double,
        logger: RunLogger?,
        subprocessName: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let recorder = logger?.beginSubprocess(
            name: subprocessName, executable: ffmpeg, arguments: args
        )
        do {
            let result = try await ProcessRunner.run(
                ffmpeg,
                arguments: args,
                onStdoutLine: { line in
                    // FFmpeg -progress writes key=value lines. We parse `out_time=`
                    // which is HH:MM:SS.ffffff — unambiguous across ffmpeg versions.
                    if line.hasPrefix("out_time=") {
                        let v = line.dropFirst("out_time=".count)
                        let parts = v.split(separator: ":")
                        if parts.count == 3,
                           let h = Double(parts[0]),
                           let m = Double(parts[1]),
                           let s = Double(parts[2]) {
                            let seconds = h * 3600 + m * 60 + s
                            if duration > 0 {
                                let frac = min(max(seconds / duration, 0), 1)
                                progress(frac)
                            }
                        }
                    } else if line.hasPrefix("progress=end") {
                        progress(1.0)
                    }
                },
                onStderrLine: { line in
                    recorder?.recordStderr(line)
                }
            )
            recorder?.finish(exitCode: result.exitCode)
        } catch {
            recorder?.finish(exitCode: -1)
            throw error
        }
    }
}
