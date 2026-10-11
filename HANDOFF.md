# Handoff: 2026-10-11

The app is now **Lacquer** (bundle ID `com.mindinmotion.lacquer`, repo-to-be `MIM18-code/lacquer`). It was "Blu-ray Compressor" until this session.

State of the project after the session that took it from a one-off build for a friend toward a public MindInMotion release. The May 2026 handoff (29 bug fixes, the UDF 2.50 ISO fix, dropping Intel) is in the baseline commit's copy of this file.

## Where it stands

**Published 2026-10-11:** Lacquer 0.2.0 beta (build 3), release `v0.2.0-beta` on github.com/MIM18-code/lacquer (tag at 50bc446, DMG SHA-256 `597732099f3c0c30ee778992e1b5f52837863723524485ea2cadf3f8cea79629`), listed on mindinmotionsoftware.com. A second Codex review (personal account, gpt-6.1-sol) found 15 defects; all fixed for 0.2.1 (see reviews/codex-review-2-2026-10-11.md). Still owed: a burned disc on hardware players.

- Builds clean with `swift build -Xswiftc -warnings-as-errors`. 31 unit tests and the end-to-end gate (`Scripts/e2e_test.sh`) pass.
- `packaging/make_dmg.sh` produces a Developer ID signed, notarized and stapled DMG (Apple accepted it with the `backlot-notary` profile).
- Not yet published. Blocked on: the new name, a hardware disc test, and a public repo.

## What changed this session

**Packaging** (`packaging/`, done by a subagent):
- Static ffmpeg/ffprobe 9.0.2 built from pinned sources with only libx264 and zimg. That replaces Homebrew's ffmpeg 8.1 and its 16 dylibs (x265, AV1, VPX, Opus, LAME, OpenSSL…).
- tsMuxeR 2.7.0 pinned by hash. Developer ID signing with hardened runtime, notarization, stapling, `SHA256SUMS`, and a GPL source archive.
- `LICENSE` (GPL-3.0) and `THIRD_PARTY_NOTICES.md`. The runtime builds in `~/Library/Caches/lacquer-runtime-build` because FFmpeg's configure breaks on the repo path's spaces.

**Architecture:** the encode moved out of the UI class into `EncodePipeline` (no UI, cancellable). `EncodePlan` computes bitrate, size and warnings without running anything, so the queue can show problems before a job starts. The app and the headless CLI (`--headless`) both drive the pipeline.

**Bugs fixed:**
- Every 1080i preset failed on ffmpeg 9: `-top 1` is no longer accepted as an encoder option. Removed; the field order comes from x264's `tff=1` and the filter chain. The e2e test checks `field_order=tt`.
- Six discrete mono tracks (Resolve/Premiere's 5.1 export) produced a mono disc, because only one stream was ever mapped. Now they're joined into 5.1 (SMPTE or film order) or stereo.
- Every file defaulted to 1080p23.976, so 25p and 29.97p masters silently dropped frames. The format now follows the source, and mismatches warn.
- No way to stop a job, and quitting left ffmpeg running (macOS doesn't kill child processes). `ProcessRunner` now terminates on task cancel and on app quit.
- Settings were snapshotted when a file was dropped, so later sidebar changes silently didn't apply. Pending jobs now read the current settings, with per-job overrides for format, audio and subtitles.
- Several failures only surfaced at the mux, after hours of encoding: a read-only source folder, a full disk, a `"` in the filename. All are now checked or fixed up before encoding.
- Failed jobs couldn't be retried. HDR sources came out washed out. SD sources kept the BT.601 matrix. Non-UTF-8 SRTs produced garbage subtitles.

**Added:**
- Output folder choice, settings saved between launches, and a time-left estimate.
- Open With and drops on the Dock icon.
- An About panel with license credits and an ISO volume label.
- A silent track for sources without audio, and the Mac kept awake during the queue.

## Review findings

A Codex review on the work account confirmed four more defects before its credits ran out: anamorphic squeeze, lost audio start offsets, cover art taken as video, and short clips failing the size check. All four are fixed, with unit and e2e regressions. Details are in `reviews/codex-review-2026-10-11.md`. That review never reached the packaging scripts.

ffmpeg prints "corrupt input packet" on every tsMuxeR M2TS. This is a false alarm: decoded frames are bit-identical to the source H.264. Don't chase it.

## Layout

| File | Role |
|---|---|
| `EncodePipeline.swift` | `EncodeRequest`, `EncodePlan` (warnings, fit, size), `OutputNaming`, `SubtitlePrep`, the run itself |
| `BluRayEncoder.swift` | Bitrate math, `videoFilterChain`, `x264Params`, `audioArguments` (pure, unit-tested) and the ffmpeg runs |
| `BDMVAuthor.swift` | tsMuxeR meta file, BDMV / ISO / M2TS authoring, output size checks |
| `MediaProbe.swift` | ffprobe parsing, `AudioStreamPicker.bestSource` |
| `Models.swift` | Standards (`suggested`, `rateNote`), settings, audio sources, jobs |
| `ProcessRunner.swift` | Non-blocking subprocess runner with cancel and kill-all |
| `EncodeCoordinator.swift` | UI queue state |
| `ContentView.swift` | UI |
| `HeadlessCLI.swift` | `--headless` mode |
| `Snapshot.swift` | `--snapshot DIR`: renders the window with sample jobs, light and dark, to PNG. Use it to check layout without screen access, and for README/site screenshots |
| `Menus/DiscMenu.swift` | Contract between the menu designer and the HDMV menu author |
| `Menus/Menu*.swift` | Menu designer: templates, three presets, planner (layout, paging, remote navigation), renderer, palette limiter, designer window. On by default; `Features.discMenus` (the `disableDiscMenus` default) can hide them |
| `Tests/`, `Scripts/e2e_test.sh` | Unit tests, end-to-end release gate |
| `packaging/` | Runtime build, signing, DMG, notarization; names in `app.env` |

## Before the first public release

1. **Name clearance.** A web search found no software called Lacquer; a USPTO TSDR search in classes 9 and 42 hasn't been done.
2. **Hardware test.** Burn a BD-R from each output mode and play it on at least two standalone players. Check chapters, subtitles (PGS render quality hasn't been looked at on a TV), 1080i29.97 PsF cadence, and audio sync over a full feature.
3. **Real HDR footage.** The tonemap chain is verified on synthetic HLG only.
4. **App icon:** drawn by `packaging/icon/make_icon.py` (writes `packaging/AppIcon.icns`). A designer pass would help, but it's usable.
5. **Public repo** under MIM18-code, `SOURCE_URL` in `app.env`, then a release with the DMG, the source archive, and ``SHA-256: `<hash>` `` at the end of the notes so mindinmotionsoftware.com picks it up.

## Roadmap

- **v2: simple disc menus.** One background still or loop with Play, Scenes (chapter thumbnails) and Subtitles on/off. Needs IGS menu streams and navigation commands written by us; tsMuxeR can't. No current Mac tool besides Toast does this, so it's what would make the app stand out. Needs testing on several players.
- Multiple audio and subtitle tracks (commentary, a second language).
- LPCM 5.1/7.1 audio as a lossless option.
- Two-pass progress weighting is per stage, not per CPU time.
