# Blu-ray Compressor

*(Working title. The app is being renamed before its first public release.)*

A Mac app that turns a finished film master into a Blu-ray: a BDMV folder, a UDF 2.50 ISO ready for a duplicator, or a single M2TS for Toast. Drop in a ProRes, DNxHR, H.264 or HEVC file, check the queue, press Start.

Apple dropped Blu-ray output from Compressor in 2018. This fills that hole for indie filmmakers sending discs to festivals, buyers and duplicators like Kunaki.

Free and open source under GPL-3.0. Apple Silicon Macs with macOS 13 or later.

## What it does

- **Picks the right Blu-ray format for each file.** Blu-ray has no 1080p25 or 1080p29.97, so 25p and 29.97p masters go out as 1080i carrying progressive frames, and 50p/59.94p are paired into fields. 23.976 and 24 stay 1080p. When a file's frame rate doesn't fit the format you forced, the queue says how many frames will be dropped or repeated before you encode.
- **Handles the audio layouts editors actually export.** A 5.1 stream is used as is. Six discrete mono tracks (Resolve and Premiere's usual 5.1 export) are joined into 5.1, in SMPTE order (L R C LFE Ls Rs) or film order (L C R Ls Rs LFE). Two mono tracks become stereo. A file with no audio gets a silent stereo track. Audio is AC-3: 640 kbps for 5.1, capped at 448 kbps for stereo.
- **Fits the disc.** The video bitrate is worked out from the running time and BD-25 or BD-50, capped under the Blu-ray maximum. A title that can't fit is refused before encoding starts. One that fits at a low bitrate gets a warning.
- **Converts color.** HDR (PQ or HLG) is tonemapped to SDR BT.709. SD sources are converted from BT.601. Interlaced sources are deinterlaced before scaling.
- **Selectable subtitles** from an .srt file, converted to PGS bitmaps during the mux. SRTs in UTF-16 or Windows-1252 are converted to UTF-8 first.
- **Chapter stops** every 5 or 10 minutes, or at times you list, for Next/Prev on the remote.
- **Checks before it spends hours.** Free space, a writable output folder and disc fit are checked before the encode starts. Temporary streams go on the output drive, not the startup disk.
- **A queue you can stop.** Stop ends the current job and deletes its partial output. Quitting mid-encode asks first and kills ffmpeg instead of leaving it running. The Mac stays awake while the queue runs.
- **A log for every job** next to its output, with every ffmpeg and tsMuxeR command, their full output, and the encode plan.

No on-screen menus yet. Discs auto-play, and chapters give Next/Prev on the remote. For menus, use the M2TS output and author it in Toast.

## Output modes

| Mode | Result | Use it to |
|---|---|---|
| BDMV Folder | `Film_BluRay/BDMV/…` | Burn with Toast or another authoring tool |
| ISO Disc Image | `Film_BluRay.iso`, UDF 2.50, written by tsMuxeR | Upload to a duplicator or `hdiutil burn` |
| M2TS File Only | `Film_BluRay.m2ts` | Author menus in Toast |

The ISO is written by tsMuxeR directly. An earlier version wrapped a BDMV folder with `hdiutil makehybrid`, which silently produced UDF 1.50 images that played on computers but failed on hardware players.

## Command line

The app binary has a headless mode for scripting and testing:

```sh
"/Applications/Blu-ray Compressor.app/Contents/MacOS/BluRayCompressor" --headless \
    --input Film.mov --mode iso --disc bd50 --output-dir ~/Discs
```

Run with `--headless` alone for the full option list. `--plan-only` prints the plan and warnings without encoding.

## Building

Needs Xcode (or the Command Line Tools) on an Apple Silicon Mac.

```sh
python3 packaging/prepare_runtime.py   # pinned FFmpeg, x264, zimg, tsMuxeR; checks SHA-256
swift build
swift test                             # unit tests
Scripts/e2e_test.sh                    # real encodes of synthetic masters, checks the discs
packaging/make_dmg.sh                  # signed, notarized DMG in packaging/dist/
```

`prepare_runtime.py` builds static ffmpeg and ffprobe with only what the app uses: libx264, zimg for tonemapping, and FFmpeg's own decoders and AC-3 encoder. Nothing is downloaded at run time. `make_dmg.sh` signs with a Developer ID identity when one is in the keychain and notarizes through a notarytool keychain profile; without one it falls back to ad-hoc signing. Names, version and bundle ID live in `packaging/app.env`.

For development, `swift run BluRayCompressor` uses Homebrew's ffmpeg and tsMuxeR if they're on the PATH, or set `DISC_TOOLS_DIR=packaging/vendor/runtime/bin`.

Intel Macs aren't supported: tsMuxeR's current releases are arm64-only for macOS, and mixing in an old x86_64 build would ship two different tsMuxeR versions.

## Why AC-3 and not Dolby Digital Plus, TrueHD or DTS

AC-3 patents expired in 2017 and FFmpeg's encoder is free to use; every Blu-ray player decodes it. E-AC-3, TrueHD, Atmos and the DTS formats are still licensed. The app says "AC-3" rather than "Dolby Digital" because the format is free and the trademark isn't.

## License

GPL-3.0, copyright MindInMotion LLC. The app bundles FFmpeg and x264 (GPL) and tsMuxeR (Apache-2.0); see `THIRD_PARTY_NOTICES.md`. Corresponding source for every release is published next to the DMG.
