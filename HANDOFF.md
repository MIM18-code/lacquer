# Handoff Notes — 2026-05-03

This doc captures the state of the project after a single working session that
delivered three feature changes, fixed 29 real bugs found across two
independent code reviews, and dropped Intel Mac support. It's aimed at
whoever picks the project up next — future you, Codex, another agent, a
contributor — and is meant to be sufficient on its own. No need to
reconstruct context from chat logs.

## TL;DR

**The app:** A SwiftUI macOS tool that takes a video master (MOV / MP4 /
ProRes) and produces a Blu-ray-ready output as a BDMV folder, a UDF 2.50
ISO, or a single M2TS file. Wraps ffmpeg + tsMuxeR. Built for indie
filmmakers shipping discs to duplication services like Kunaki.

**Apple Silicon only.** Intel Mac support was deliberately dropped — see
"Why no Intel" below. Don't re-add it without a strategy for the upstream
tsMuxeR x86_64 staleness problem.

**Three feature changes this session:**

1. **Selectable PGS subtitles** from a per-job .srt — tsMuxeR converts to
   bitmap PGS at mux time. UI: per-job "Add SRT…" button.
2. **Layout-aware audio.** All audio streams are enumerated with their
   `channel_layout` tags; the most likely surround program is auto-picked
   (with a tiebreak penalty for "Lt/Rt" / "downmix" / "commentary"
   tracks); ambiguous 8-channel sources show an orange "layout unknown"
   badge. User can override per job.
3. **Per-job diagnostic log.** Every run writes a `.log` next to its
   output containing the full ffmpeg / tsMuxeR argv, complete stderr, the
   tsMuxeR meta file content, and the resolved encode plan. Failures
   include the log path in the user-visible error.

**One critical bug fix:** the ISO output path no longer routes through
`hdiutil makehybrid`, which silently downgraded the image to UDF 1.50.
tsMuxeR writes the .iso directly. Codex's smoke test confirmed the
resulting image carries an `NSR03` anchor (UDF 2.50). The earlier code
would have produced ISOs that played in software but failed on hardware
Blu-ray players — exactly the worst kind of bug for a Kunaki workflow.

## Build state

```bash
swift build -Xswiftc -warnings-as-errors   # clean, no warnings
./Scripts/build-app.sh                      # produces fresh .app/.dmg/.zip
```

Current artifacts in `build/`:

- `Blu-ray Compressor.app` — arm64 native, ad-hoc signed, ~37 MB
- `Blu-ray Compressor.dmg` — for distribution, ~17 MB
- `Blu-ray Compressor.zip` — alternative for chat/email, ~17 MB

All three bundled tools (ffmpeg 8.1, ffprobe 8.1, tsMuxeR 2.7.0) verified
to launch from the bundle. Codesign passes `--deep --strict`.

## What changed (29 fixes)

> Fix #17 is critical: prior to it, all 1080i presets silently produced
> progressive H.264 streams (the `interlaced=tff` x264 param is rejected
> by libx264 with "Error parsing option"; the correct syntax is `tff=1`).
> Anyone who built an interlaced disc on a previous build of this app
> will need to re-encode.


These are listed in the order they were caught, not severity. Each was a
real bug at time of fix.

### Caught by my own pass

| # | Bug | Fix location |
|---|---|---|
| 1 | `hdiutil makehybrid` silently produces UDF 1.50 | `BDMVAuthor.authorISO` uses tsMuxeR's `.iso` writer; `ISOBuilder.swift` deleted |
| 2 | `MediaProbe` only counted channels, ignored `channel_layout`; only read first audio stream | Rewrote to enumerate all streams; added `AudioStreamPicker` |
| 3 | `font-name="Arial"` quoted incorrectly per tsMuxeR docs | Now `font-name=Arial` |

### Caught by code-reviewer agent

| # | Bug | Fix location |
|---|---|---|
| 4 | Path injection — paths with `"` corrupt the meta file | `BDMVAuthor.AuthorError.unsupportedPath` rejects up-front |
| 5 | tsMuxeR can exit 0 with empty/truncated output | `assertOutputBytes` post-mux check (1 MiB ISO, 1 KiB M2TS, BDMV stream m2ts ≥ 1 MiB) |
| 6 | `RunLogger.closeWithStatus` could race with stderr callbacks | Added `isClosed` flag guarded by existing NSLock |
| 7 | `setSubtitle` / `setAudioStream` had no `.running` guard | Mutators now no-op while job is running |
| 8 | `whichViaShell` interpolated tool name into shell string | Tool name now passed as positional argv `--` "$1" |

### Caught by Codex

| # | Bug | Fix location |
|---|---|---|
| 9 | Mux meta passed source fps, but encoded H.264 is at preset fps | `EncodeCoordinator` passes `preset.standard.frameRateValue` to all three author calls |
| 10 | `font-color=0x00FFFFFF` is alpha=0 → fully transparent subtitles | Now `0xFFFFFF` (24-bit RGB) |
| 11 | BDMV mode only checked filename existence, not size | Largest stream m2ts validated via `assertOutputBytes` |
| 12 | README still described `hdiutil` ISO flow | README rewritten |
| 13 | M2TS mode emitted `--blu-ray` and produced a BDMV folder, not a file | New `bluRayMode` parameter on `runMux`; M2TS-only mode omits it |
| 14 | `font-charset=1` was rejected at runtime by tsMuxeR 2.7.0 | Removed; tsMuxeR uses default |
| 15 | Same-rate progressive→interlaced (25p→25i, 29.97p→29.97i) used `interlace=scan=tff`, which paired frames and halved cadence — `-r` then duplicated frames back, causing stutter | `BluRayEncoder.encodeVideo` now branches on source vs target fps: ratio ≥ 1.5 uses `interlace` (correct field-pair); near-1× uses `setfield=mode=tff` (PsF, no field merging) |
| 16 | M2TS-only mode silently accepted `--custom-chapters` but had no MPLS playlist to hold them, so chapters disappeared without warning | `BDMVAuthor.metaFile` gates `--custom-chapters` on `bluRayMode`; `EncodeCoordinator` warns the user (UI log + run log) when chapters are configured for M2TS-only output |
| 17 | x264 param `interlaced=tff` is rejected by libx264 ("Error parsing option"); ffmpeg falls back to progressive defaults so all 1080i presets silently produced progressive H.264 (`field_order=progressive`) | `BluRayEncoder` now emits `tff=1`, the syntax libx264 actually accepts. Verified with ffprobe: `field_order=tt` |
| 18 | The 1.5× ratio guard for the `interlace` filter let cross-standard cases through (50p→29.97i has ratio ≈ 1.67), pairing frames down to 25 fps and then duplicating back to 29.97 — the same stutter fix #15 was meant to prevent | Tightened guard to `abs(ratio − 2.0) < 0.05`; only true near-2× cases (50/25, 59.94/29.97, 60/29.97) take the `interlace` path. Everything else uses `setfield=mode=tff` |
| 19 | Two-pass passlog cleanup ran only after pass 2 returned, so a pass-1 failure leaked the libx264 stats files into `/tmp` permanently. Suffix list also included three never-written entries (`""`, `".log"`, `".log.mbtree"`) | Cleanup moved to `defer` immediately after `passlog` is assigned; suffix list trimmed to the two libx264 actually writes |
| 20 | `MediaProbe` read `r_frame_rate` for source frame rate, but ffprobe reports the *field* rate there for genuine interlaced sources (1080i/29.97 → 60000/1001 instead of 30000/1001). Today this is a UI lie; if the ratio guard ever extends to interlaced sources it would be off by 2× | Prefer `avg_frame_rate`, fall back to `r_frame_rate` only when the avg is missing/zero |
| 21 | `EncodeCoordinator` hardcoded `languageCode: "eng"` on every PGS subtitle track, ignoring the `SubtitleTrack.languageCode` parameter. Spanish/French/etc. subs would tag `lang=eng` and players that filter by preferred language wouldn't surface them | Added `EncodeJob.subtitleLanguageCode`, a `setSubtitleLanguage` mutator, a 13-language picker in the per-job UI, and threading from job → `SubtitleTrack` |
| 22 | `validatePath` rejected `"` but allowed `\n` / `\r`. APFS permits newline characters in file names; such a path would split the meta file mid-line | Now also rejects `\n` and `\r` up front |
| 23 | `formatChapterTime` truncated whole seconds with `Int(seconds)` and rounded the remainder to ms — floating-point drift in auto-chapter accumulation could push the fractional part to ≥ 0.9995, yielding a 4-digit ms field (`00:05:00.1000`) | Round to integer milliseconds first, then split — `300.9999999` cleanly produces `00:05:01.000`. Verified |
| 24 | Interlaced source + progressive preset had no deinterlacer in the filter chain — combed fields would be encoded as if they were progressive frames | `BluRayEncoder.encodeVideo` inserts `bwdif=mode=send_frame:parity=auto:deint=all` when `sourceIsInterlaced && !standard.isInterlaced` |
| 25 | README still described `interlaced=tff` (rejected by libx264) and `interlace=scan=tff` for all progressive sources — both stale after #17/#18 | Rewrote the encoding-parameters section to describe `tff=1` and the source-fps-aware branch (`interlace` for ~2× sources, `setfield` otherwise, `bwdif` for interlaced→progressive) |
| 26 | The `bwdif` deinterlacer (#24) ran AFTER `scale,pad`, so the scaler saw combed interlaced frames and blended fields together (especially visible on 1080i → 720p downscales) before `bwdif` ever got a clean shot at separating them | Filter chain restructured: `bwdif → scale → pad → setsar → [interlace/setfield] → format`. Deinterlacer now runs on full-resolution interlaced source before any scaling |
| 27 | `bwdif=mode=send_frame` was unconditional, halving temporal information on 1080i → 720p doubled-rate conversions (1080i29.97 → 720p59.94 yielded 29.97 progressive frames, then `-r` duplicated to 59.94 — full half of the source's motion was lost) | Mode now branches on target/source fps ratio: `send_field` when target ≈ 2× source (1080i29.97 → 720p59.94, 1080i25 → 720p50), `send_frame` otherwise. Verified live: send_field yields 120 frames per 2s of 30/1.001 source = 59.94 fps |
| 28 | `formatChapterTime` traps on `Double.nan` / `Double.infinity` (Swift `Int(NaN)` is undefined behavior → fatal error) and emits malformed strings on negative input. Not currently reachable — `ChaptersConfig.chapterTimes` only emits non-negative finite values — but a future caller bypassing those filters would crash mid-encode | Added defense-in-depth guard: `guard seconds.isFinite, seconds >= 0 else { return "00:00:00.000" }`. Verified live: NaN/+inf/-inf/-1.0 all fail soft to start-of-title; all valid inputs unchanged |
| 29 | `videoBitrate` enforced an 8 Mbps "floor" intended as a quality target, but it was a *hard* floor in the math — for long titles where the disc-fit value would naturally be lower, the function silently returned 8 Mbps anyway and the encode overshot the disc. Codex's example: BD-25, 8 hours, 640 kbps audio → 8 Mbps × 8 h + audio = 31.1 GB on a 23.4 GB disc | Renamed the 8 Mbps constant to `videoBitrateQualityFloor` (no longer enforced in math), lowered the math's absolute floor to 1 Mbps (encoder-sane minimum), added `fitsOnDisc(...)` helper, and wired the coordinator to (a) fail-fast with a useful error when the title is physically too long for the selected disc, (b) warn loudly when the planned bitrate is below the quality floor. Verified: Codex's 8h/BD-25 case now produces 5.86 Mbps × FITS with a low-quality warning; 100h/BD-25 case fails fast |

Codex also did a real ISO smoke test and confirmed `NSR03` (UDF 2.50) in
the output. That was the single biggest open question in the previous
HANDOFF; it is now closed.

## Architecture (still accurate)

```
ContentView (SwiftUI)
    │ drops video files
    ▼
EncodeCoordinator (@MainActor)        ← per-job mutators (subtitle, audio idx)
    │
    ├── MediaProbe ──── ffprobe ──── reads all audio streams + layouts
    │     └── AudioStreamPicker auto-picks the surround program
    │
    ├── BluRayEncoder ─ ffmpeg ──── H.264 video (with letterbox/pillarbox)
    │                              + AC-3 audio via -map 0:N
    │
    └── BDMVAuthor ──── tsMuxeR ─── BDMV folder | single M2TS | UDF 2.50 ISO
            └── meta file with optional S_TEXT/UTF8 subtitle line
                (tsMuxeR converts SRT → PGS at mux time)
            └── post-mux size validation via assertOutputBytes
            └── all subprocess output teed into RunLogger
```

`RunLogger` writes `<output>.log` with the full diagnostic trail. On
failure, the user-visible error includes the log path so it's a single
artifact for support / cross-tool review.

## Files of interest

| File | Why you'd open it |
|---|---|
| `Sources/BluRayCompressor/BDMVAuthor.swift` | tsMuxeR meta file generation, ISO/M2TS/BDMV authoring, all output validation |
| `Sources/BluRayCompressor/MediaProbe.swift` | Audio stream enumeration + `AudioStreamPicker` scoring |
| `Sources/BluRayCompressor/BluRayEncoder.swift` | ffmpeg invocations; aspect-preserving scale+pad lives here |
| `Sources/BluRayCompressor/EncodeCoordinator.swift` | Per-job orchestration, RunLogger lifecycle, font-availability warning |
| `Sources/BluRayCompressor/RunLogger.swift` | The diagnostic log file format |
| `Sources/BluRayCompressor/ContentView.swift` | Per-job UI: SRT picker, audio stream picker, ambiguity badge |
| `Scripts/build-app.sh` | The one supported build path. arm64 only, Apple Silicon only. |

## Why no Intel

`Scripts/build-universal.sh` was deleted this session. The reasoning:

- tsMuxeR upstream (justdan96 fork) **never shipped a universal Mac
  binary**. They ship arm64-only stable releases (current 2.7.0) and used
  to ship x86_64-only nightlies. Mid-2024 they stopped shipping Mac
  builds in nightlies entirely.
- Building a Universal bundle therefore requires `lipo`-ing arm64 from
  2.7.0 against an x86_64 slice from a ~13-month-old nightly. That's a
  silent version mismatch baked into the binary — Intel users would run
  tsMuxeR 13 months older than Apple Silicon users.
- For an indie-filmmaker tool whose audience runs current Macs, the risk
  of mismatched-tsMuxeR bugs outweighs the benefit of Intel support.

If someone needs Intel later, the path is to commission an x86_64 build
of current tsMuxeR upstream — not to resurrect the lipo hack.

## Verification still owed

These can only be done with hardware the dev environment doesn't have:

1. **Real-disc burn test on a hardware Blu-ray player.** All structural
   validations are in code (`NSR03` confirmed, BDMV stream files
   non-zero, codesign deep-strict passes), but only a real player
   verifies playback navigation, audio sync over the long haul, and
   subtitle visibility.
2. **PGS subtitle render quality.** Defaults in
   `BDMVAuthor.subtitleLine(...)` (Arial 65pt, 21px bottom offset, 2px
   border) haven't been visually tested. If subs look wrong, that single
   function is where to tweak.
3. **`AudioStreamPicker` against a corpus of real masters.** The scoring
   penalty for "Lt/Rt"/"downmix"/"commentary" titles is heuristic. A
   user file with those words in a legitimate primary-track title would
   misrank. Override is always available in the UI.

## Known limitations (intentional)

- AC-3 5.1 max for audio. True 7.1 sources are downmixed to 5.1. LPCM
  7.1 would be the upgrade path; deferred until someone asks.
- No DTS-HD MA / TrueHD encoding — no Mac-native encoder exists for
  those.
- Subtitle styling isn't exposed in the UI.
- Single subtitle track only. Multi-language is mostly more
  `S_TEXT/UTF8` lines in the meta file; the UI plumbing is the work.
- No 8-channel-stream Lt/Rt vs 7.1 spectral disambiguation. The picker
  flags ambiguity visually and lets the user decide.
- No on-screen menu authoring. Use the M2TS output mode + Toast 20 for
  that.

## Debugging cookbook

**A user reports the disc fails to play / has no subtitles / wrong rate.**

1. Find the per-job log: `<input>_BluRay.log` (next to the output file).
2. Top of the log has the resolved run plan — confirm preset matched
   intent.
3. The log has full ffmpeg argv + stderr for video and audio, then the
   tsMuxeR meta file content, then tsMuxeR's stderr.
4. Most common failures and where they show up:
   - Wrong frame rate on the disc → `EncodeCoordinator` log line
     "audio source: stream[N]" should match expected rate; cross-check
     the `fps=...` in the captured meta file.
   - Empty subtitles → check the log for `Can't load charset` (tsMuxeR
     can't find the font) or no Arial.ttf warning. tsMuxeR resolves
     `/Library/Fonts/Arial.ttf` and `/System/Library/Fonts/Supplemental/Arial.ttf`.
   - Stretched/squished video → confirm `force_original_aspect_ratio=decrease`
     is in the ffmpeg `-vf` chain in the log.
   - Disc plays in VLC but fails on hardware → almost always was the
     UDF 1.50 bug (now fixed). Verify the `.iso` has `NSR03`:
     ```bash
     xxd "<file>.iso" | grep "NSR0" | head -3
     ```

**Build is broken / won't compile.**

```bash
swift build -Xswiftc -warnings-as-errors  # catches everything
```

If you see SwiftBridging or SDK module errors, it's the Command Line
Tools / SDK version mismatch — re-install CLT (see README "If swift build
fails on your machine").

**The .app bundle is stale / has old code.**

```bash
./Scripts/build-app.sh                    # always rebuilds clean
```

The script always wipes and re-creates the bundle, so a stale `.app` just
means the script wasn't re-run after the source change.

## Quick command reference

```bash
# Build the Swift binary (debug)
swift build

# Build with strict warnings
swift build -Xswiftc -warnings-as-errors

# Build the .app bundle for distribution
./Scripts/build-app.sh

# Run the app from the built bundle
open "build/Blu-ray Compressor.app"

# Inspect a built ISO's UDF version
xxd "<file>.iso" | grep "NSR0" | head -3
# NSR03 = UDF 2.50 (correct). NSR02 = UDF 1.50 (the old bug).

# Inspect a source MOV's audio layout
ffprobe -v error -select_streams a \
  -show_entries stream=index,codec_name,channels,channel_layout \
  -of default=noprint_wrappers=1 "<file>.mov"

# Tail a running encode's log
tail -f "<input>_BluRay.log"
```

## Change ownership

All edits in this session are listed in the "What changed" table above.
The build was verified clean with `swift build -Xswiftc -warnings-as-errors`
after the final source edit. The `.app` bundle was rebuilt as the last
step, so the timestamp on `build/Blu-ray Compressor.app/Contents/MacOS/BluRayCompressor`
reflects the latest source.

The project ships no test target. Adding one is its own project.
