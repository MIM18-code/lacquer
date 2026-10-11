# HDMV menu backend

How Lacquer turns a `DiscMenu` (from `Sources/Lacquer/Menus/DiscMenu.swift`) into Blu-ray menus, what has been checked, and what hasn't.

## What it produces

For BDMV folder and ISO output, when `EncodeRequest.menu` is set:

- tsMuxeR writes the film as before: `00000.m2ts/.clpi/.mpls` with chapters, AC-3 and PG subtitles.
- Each menu page gets its own clip `01000 + page`. The clip carries the page background as 1080p23.976 H.264, a silent AC-3 track and an Interactive Graphics (IG) stream holding the buttons. Lacquer writes the M2TS, CLPI and MPLS for it.
- `MovieObject.bdmv` is replaced. Object 0 is the film (title 1). Object 1 + p stores page p's default button in PSR10, then plays the page's playlist in a loop. The page's IG composition names no default button, so players take PSR10, and a loop restart keeps the viewer's selection.
- `index.bdmv` is replaced. First Play and Top Menu both open the first page.
- Everything new is also copied into `BDMV/BACKUP`.
- ISO output with a menu authors the folder in the work directory, then writes it with `UDFImageWriter`. That is a Swift port of tsMuxeR's UDF 2.50 writer. With `--constant-iso-hdr` its output is byte-identical to tsMuxeR's image of the same folder.

M2TS-only output ignores the menu, and the plan says so.

## Why not tsMuxeR for the menus

tsMuxeR 2.7.0 has no IG input. Its graphics reader (`pgsStreamReader.cpp`) passes an interactive composition segment through but labels the stream as PG (0x90). Its ISO writer only images files it muxed itself. So tsMuxeR keeps the film, and the menu clips, navigation files and image are written here.

## Navigation

| Button action | Commands |
|---|---|
| `playFilm` | GPR0 = 0, Jump Title 1 |
| `playChapter(n)` | GPR0 = n, Jump Title 1 |
| `goToPage(q)` | Jump Object 1 + q |
| `setSubtitles(on:)` | GPR2 = 1 or 0, re-select the button |

The film object turns PG stream 1 on or off from GPR2. It plays 00000.mpls from the mark in GPR0, or from the start when GPR0 is 0, and returns to the first page when the film ends. Button commands can't start playlists themselves, so they go through the film title. Chapter n is playlist mark n. tsMuxeR writes one mark per entry in `plan.chapterTimes`.

Chapters now sit on IDR frames. Chapter times snap to frame starts, the film encode forces a keyframe at each one, and the mark is rounded up to the millisecond. Before, a chapter at 20 s started at the previous GOP, 19.0 s.

## Contract notes for the designer

- `setSubtitles` buttons are rejected when the film has no subtitle track, and `playChapter(n)` when n is past the last chapter.
- Each page's button images share one palette of 255 colours plus transparent. Pages with more colours are median-cut reduced, without dithering. Flat colours and clean alpha look best.
- Every state image must match its button's `rect` size, and the rect must lie inside 1920×1080. Fractional rects are rounded.
- `loopSeconds` above 0 loops the background clip. 0 or less plays a one-second clip and holds it with an infinite still (`--menu-demo --menu-loop 0`).
- Menus are always 1080p23.976, whatever the film's format.

## Verified

`Scripts/menu-check` drives a disc through libbluray 1.5.0's HDMV navigation (the code VLC uses). Build it with `Scripts/menu-check/build.sh` (needs `brew install libbluray`). Run it on `--menu-demo` output: `menu_check DISC --chapters 0,20,40 --subtitles`, adding `--still` for a still menu. All 19 checks pass on the BDMV folder, on the ISO, and on a still menu:

- First Play shows the 4-button main page, with Play selected.
- Down and Up move the selection. Right with no neighbour does nothing.
- The selection survives the menu loop restarting. A still menu holds and stays live.
- Play draws activated and starts title 1 (00000.mpls) at 0:00.
- Top Menu during the film returns to the menu.
- Scenes opens the chapter page. Each chapter button starts at its chapter (0.00, 20.01, 39.99 s).
- Back returns to the main page.
- Subtitles On and Off keep the menu up, and the film then plays with PG stream 1 shown or hidden.

`swift test` has byte-level tests for every writer. The MPLS writer reproduces tsMuxeR's film playlist byte for byte. `Scripts/e2e_test.sh` authors a menu disc as a folder and as an ISO, mounts the ISO, checks the streams, and runs the harness when it builds.

## Not verified

No hardware player has played these discs. These choices follow the spec as libbluray and tsMuxeR read it, but only a real player can confirm them:

- IG timing. Segment decode and presentation times assume 16 Mbit/s delivery, an 8 Mpixel/s object decode rate, and a plane clear of about 130 ms. libbluray ignores IG timestamps.
- `composition_timeout_pts` and `selection_timeout_pts` are set to the clip's end, not 0. The spec text on 0 wasn't available.
- A looping menu redraws its buttons when the clip restarts (the IG epoch starts again). libbluray keeps the selection, but a player may blink the buttons.
- Large pages. The IG coded-data buffer is small (about 1 MB). Many big, detailed buttons could exceed it, and nothing checks for that yet.
- Menu video: no B-frames, CRF 16 with a 15 Mbit/s VBV, four slices, level 4.1, one-second GOPs.

Test plan: burn the `--menu-demo` ISO to BD-R and try it on two or three players (a PS4/PS5 or Xbox and a standalone Sony or Panasonic). Check that the menu appears, the remote moves the selection, each button works, Top Menu works during the film, and the menu loop doesn't flicker.

## Files

`Sources/Lacquer/Menus/`: `HDMVMenuAuthor` (orchestration and navigation), `IGSEncoder` (palette, RLE, ICS/PDS/ODS/END), `M2TSMuxer`, `ClipInfoWriter`, `PlaylistWriter`, `MovieObjectWriter`, `IndexWriter`, `UDFImageWriter`, `ByteWriter`, `MenuDemo`.

CLI: `--menu-demo` adds the demo menu. `--iso-from FOLDER --output X.iso` writes any BDMV folder as a UDF 2.50 image.
