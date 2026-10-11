# Blu-ray Compressor

A macOS SwiftUI app that takes a ProRes / MOV / MP4 master and produces a
Blu-ray-compliant output ready to burn — as a **BDMV folder**, a **UDF 2.50
ISO disc image**, or a single **M2TS file** for use with Toast 20.

Built to fill the hole Apple left when Compressor 4.4 (2018) dropped Blu-ray
output.

## What it does

- Transcodes video to **H.264** with strict Blu-ray compliance flags
  (profile/level, 1-second GOP, HRD, AUD, BT.709 color).
- Supports **progressive and interlaced** output: 1080p23.976/24, 1080i29.97/25,
  720p59.94/50/23.976/24.
- Encodes audio to **AC-3 5.1** at 448 or 640 kbps via FFmpeg's built-in AC-3
  encoder. Core patents expired March 2017, so this is free to use. The UI
  calls it "AC-3 5.1" rather than "Dolby Digital" because the *format* is
  free, the Dolby trademark isn't.
- Computes the target video bitrate automatically so the encode fits BD-25 or
  BD-50 with ~2% overhead.
- Adds **chapter stops** for Next/Prev navigation — auto-every-N-minutes or a
  custom list.
- Muxes into a BDMV folder with **tsMuxeR**, writes a single M2TS, or emits
  a **UDF 2.50 ISO** directly. tsMuxeR's own ISO writer is used — earlier
  versions of the app wrapped the BDMV via `hdiutil makehybrid -udf-version
  2.50`, which silently downgraded the image to UDF 1.50 and produced ISOs
  that played in software but failed on hardware Blu-ray players.
- **Selectable PGS subtitles** from a per-job .srt file. tsMuxeR converts
  the text to bitmap subtitles at mux time so the resulting disc has soft
  subs you can toggle from the remote, not burned-in pixels.
- **Layout-aware audio.** Reads `channel_layout` for every stream in the
  source, auto-picks the most likely surround program (with a tiebreak
  penalty for tracks tagged "Lt/Rt", "downmix", "commentary"), flags
  ambiguous 8-channel streams in the UI, and lets the user override the
  audio track per job.
- **Per-job diagnostic log.** Every run writes a `.log` next to its output
  containing the full ffmpeg/tsMuxeR argv, complete stderr, the tsMuxeR
  meta file content, and the resolved encode plan.
- **Job queue**: drop multiple files, run them all sequentially.

## Requirements

**macOS 13+** and these command-line tools on your `PATH`:

```sh
brew install ffmpeg
```

**tsMuxeR** no longer has an official Homebrew formula. Install it manually:

1. Download a recent release from <https://github.com/justdan96/tsMuxer/releases>
2. Extract the archive; inside you'll find a `tsMuxeR` binary.
3. Copy it to a directory on your PATH:
   ```sh
   sudo cp tsMuxeR /usr/local/bin/
   sudo chmod +x /usr/local/bin/tsMuxeR
   ```

The app searches `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`,
`/usr/bin`, and `/bin`, then falls back to asking your login shell via
`command -v`. Missing tools show an orange warning in the sidebar.

## Build & run

### Option A — Xcode (development)

```sh
open Package.swift
```

Xcode opens the project as a Swift Package. Hit Run.

### Option B — Command line

```sh
swift run BluRayCompressor
```

Produces an unbundled binary with a SwiftUI window. No code signing, no `.app`.
Fine for iterating.

### Option C — Build a packaged .app

Use the bundled build script:

```sh
./Scripts/build-app.sh
```

This:

1. Builds an arm64 release binary. **Apple Silicon only** — Intel Mac
   support was dropped because the upstream tsMuxeR project no longer
   ships current x86_64 builds, and combining current arm64 + 13-month-old
   x86_64 slices is a correctness risk we don't want to ship.
2. Bundles ffmpeg, ffprobe, and tsMuxeR (plus all dynamic-library
   dependencies) inside the .app so the recipient doesn't need Homebrew.
3. Assembles `build/Blu-ray Compressor.app` with a correct Info.plist.
4. Ad-hoc codesigns it so Gatekeeper lets you run it on this Mac without
   prompts.
5. Produces a `.dmg` and `.zip` for distribution.

Then:

```sh
open "build/Blu-ray Compressor.app"
# or
cp -R "build/Blu-ray Compressor.app" /Applications/
```

For distribution to other users you'd replace the ad-hoc sign in the script
with a Developer ID certificate and run the bundle through `notarytool
submit`.

### If `swift build` fails on your machine

If you see errors like `redefinition of module 'SwiftBridging'` or
`this SDK is not supported by the compiler`, your Command Line Tools install
is inconsistent — the SDK and compiler were updated out of sync. This
happens when `softwareupdate` only partially refreshes CLT. Fix:

```sh
sudo rm -rf /Library/Developer/CommandLineTools
sudo xcode-select --install
```

The installer prompt appears; click Install and wait for it to finish (a
few GB download). After it completes, `swift build` will work.

Alternative: install full Xcode from the App Store — that ships its own
complete toolchain and bypasses the CLT-only issue entirely.

## Using it

1. Drop one or more video files onto the window, or click **Choose Files…**.
2. Configure the sidebar: disc size, video standard, audio bitrate, chapters,
   output mode.
3. Click **Start Queue**. Jobs run sequentially.
4. Finished jobs show a folder icon — click it to reveal the output in
   Finder.

Settings apply to new jobs as you add them. Change settings between drops to
mix configurations in one queue.

## Output modes

| Mode | Result | How to burn |
|---|---|---|
| **BDMV Folder** | `MyFilm_BluRay/BDMV/…` | Disk Utility, Toast 20 "Blu-ray Video → From folder" |
| **ISO Disc Image** | `MyFilm_BluRay.iso` (UDF 2.50, written by tsMuxeR directly) | Disk Utility, Toast, or `hdiutil burn MyFilm_BluRay.iso` |
| **M2TS File Only** | `MyFilm_BluRay.m2ts` | Drop into a Toast 20 Blu-ray project for on-screen menu authoring |

## Chapters vs on-screen menus

The built-in **chapter stops** give you the skip-forward / skip-back navigation
most real-world Blu-rays need. On a remote, Next/Prev jumps between chapter
points — no on-screen menu, but viewers can get around.

For **full on-screen menus** (Play / Scene Selection / Special Features with
animated backgrounds), use the **M2TS File Only** output mode and import the
result into Toast 20. Toast handles the HDMV menu authoring that this app
deliberately doesn't — that's several more weeks of work and Toast is already
good at it.

## Why no Dolby Digital Plus / 7.1 / Atmos?

Core **AC-3 (original Dolby Digital 5.1)** patents expired in March 2017 and
FFmpeg's built-in encoder is freely usable. It produces a spec-legal 5.1
bitstream every Blu-ray player decodes.

**Dolby Digital Plus (E-AC-3)**, TrueHD, Atmos, DTS, DTS-HD MA, and DTS:X all
have active patents and/or commercial licensing. Shipping encoders for them
without a Dolby/DTS license is legally murky, so this app doesn't.

AC-3 5.1 at 640 kbps is universal and sounds indistinguishable from lossless
options for almost all content. It's the right default.

## Encoding parameters

For the curious, here's what the pipeline passes to x264 for a 1080p/23.976
Blu-ray:

```
-profile:v high -level:v 4.1 -preset slow
-x264-params bluray-compat=1:level=4.1:keyint=24:min-keyint=24:
              bframes=3:b-pyramid=strict:weightp=0:weightb=1:ref=3:
              aud=1:nal-hrd=vbr:colorprim=bt709:transfer=bt709:
              colormatrix=bt709:slices=4
-maxrate 35000k -bufsize 30000k
-pix_fmt yuv420p
```

For interlaced output (1080i29.97 or 1080i25) the pipeline additionally adds
`-flags +ildct+ilme -top 1` and `:tff=1` to x264 params (the libx264-correct
syntax — `interlaced=tff` is rejected at parse time and silently produces
progressive H.264).

When the source is progressive and the output is interlaced, the video
filter chain adapts based on the source frame rate:

- **Source ≈ 2× target** (50p → 25i, 59.94p → 29.97i): `interlace=scan=tff`
  pairs adjacent frames into top/bottom fields. Halves frame rate, keeps
  field rate intact.
- **Anything else** (25p → 25i, 29.97p → 29.97i, 50p → 29.97i, 23.976p →
  29.97i): `setfield=mode=tff` flags each frame as Progressive Segmented
  Frame. x264's `tff=1` then encodes it as a pair of fields without
  changing the cadence — avoids the stutter the `interlace` filter would
  introduce when source and target are at the same nominal rate.

When the source is interlaced and the output is progressive, `bwdif` is
inserted into the filter chain to deinterlace before scaling.

Audio: `-c:a ac3 -b:a 640k -ac 6 -ar 48000`.

Video bitrate is auto-computed from duration and disc size, capped at
34,500 kbps to stay safely under the 40 Mbps Blu-ray A/V ceiling.

## Status

**Alpha, but the core pipeline is verified end-to-end.** Every ffmpeg /
tsMuxeR command the app issues has been run against a 15s synthetic
ProRes+5.1 test clip and confirmed to produce spec-compliant output:

- **H.264 output**: High profile, Level 4.1, 1920×1080, yuv420p, BT.709
  color, 2 B-frames, progressive — probed via ffprobe against the raw
  elementary stream.
- **AC-3 output**: 48 kHz, 6 channels, 5.1(side) layout, 640 kbps — probed
  against the raw AC-3 stream.
- **Muxed M2TS**: video at PID 0x1011 (Blu-ray primary video PID), audio at
  PID 0x1100 (Blu-ray primary audio PID), both tracks carried through with
  original parameters intact — probed from inside `BDMV/STREAM/00000.m2ts`.
- **BDMV folder**: complete structure — `index.bdmv`, `MovieObject.bdmv`,
  `PLAYLIST/00000.mpls`, `CLIPINF/00000.clpi`, `STREAM/00000.m2ts`,
  `BACKUP/*`, `CERTIFICATE/` — matches the Blu-ray filesystem spec.
- **UDF 2.50 ISO**: written directly by tsMuxeR via its `.iso` output mode.
  The image's UDF anchor reports `NSR03` (UDF 2.50) when inspected, mounts
  cleanly via `hdiutil attach`, and the filesystem shows up as
  `/Volumes/<name>` with the full BDMV tree readable from userspace.
- **Chapters**: custom chapter timestamps are written into the MPLS
  playlist as PlayListMark entries.

One meta-file bug caught during verification: the original tsMuxeR meta
file included explicit `track=4113` / `track=4352` PIDs and
`--new-audio-pes`. tsMuxeR silently produced an audio-only mux
("Processed 0 video frames") with those options. Removing them lets
tsMuxeR assign its own defaults, which happen to be the Blu-ray-standard
PIDs anyway. Fixed in `Sources/BluRayCompressor/BDMVAuthor.swift`.

### Delivered in this build
- ✓ H.264 video encoding with full Blu-ray compliance flag set
- ✓ AC-3 audio encoding at 448 / 640 kbps, layout-aware track selection
- ✓ Direct `.iso` output via tsMuxeR (UDF 2.50, burnable as-is — no
  `hdiutil` wrap step that silently downgraded to UDF 1.50)
- ✓ BDMV folder output (for Toast 20 import or direct Disk Utility burn)
- ✓ Single M2TS output (for Toast 20 menu authoring handoff)
- ✓ Selectable PGS subtitles from .srt files
- ✓ Per-job audio track override + ambiguous-layout warnings in the queue
- ✓ Chapter markers (auto-every-N-minutes or custom list)
- ✓ Job queue (multi-file drop, sequential processing)
- ✓ Per-job `.log` files with full ffmpeg/tsMuxeR diagnostics
- ✓ `.app` bundle packaging via `Scripts/build-app.sh`

### Still to do
- No on-screen HDMV menu authoring (use Toast via M2TS mode).
- No app icon (generic default).
- Progress is per-stage weighted, not CPU-time-weighted.
- No cancel button mid-encode (close the window to kill it).
- **Burn a real disc and test in your actual player.** Mounting an ISO
  proves the filesystem is valid but not that a standalone Blu-ray player
  will navigate it the way you expect.

## License

MIT.
