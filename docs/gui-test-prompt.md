# GUI test pass for Lacquer (prompt for Codex with computer use)

Paste everything below the line into Codex. It tests the notarized DMG at `packaging/dist/Lacquer-0.2.0-arm64.dmg`; change the version if it has moved on.

---

Test the Mac app Lacquer through its real GUI, using computer use, and report every defect you find. Lacquer turns a finished film master into a Blu-ray: a BDMV folder, a UDF 2.50 ISO, or an M2TS, optionally with an on-screen disc menu. The repo is `~/Documents/Blu Ray Compression App`. `README.md` describes what the app should do; `reviews/gui-pass-2026-10-11.md` lists what an earlier pass already checked and fixed. Unit tests and `Scripts/e2e_test.sh` cover the encode logic. This pass is about what a person sees and does: layout, wording, state changes, errors, the menu designer, and whether the discs it writes match what the UI promised, menus included.

## Ground rules

- Report only. Don't edit the repo, commit, push or publish anything.
- Work under `~/Desktop/lacquer-gui-test-2/` with `fixtures/`, `out/` and `shots/` inside. Take a screenshot at each state named below and save it with a descriptive name.
- Make fixtures with `/opt/homebrew/bin/ffmpeg`. Inspect outputs with ffprobe, and mount ISOs with `hdiutil attach -readonly`.
- Short fixtures encode in under a minute. If anything hangs past 5 minutes, record it, quit the app and move on.
- If your computer-use helper can't read Lacquer's window, record the exact error once and stop instead of retrying. The last pass hit a helper crash; controls have since been given accessibility labels.

## Setup

1. Mount the DMG and drag Lacquer to Applications through the window's Applications shortcut, replacing any older copy. Eject. Opening it from Applications must show no Gatekeeper warning.
2. Fixtures:
   - `mono6.mov`: 30 s ProRes 1080p23.976, six mono PCM tracks (sine 220, 330, 440, 60, 550, 880 Hz = L R C LFE Ls Rs).
   - `phone.mp4`: 30 s H.264 1080p29.97, stereo AAC.
   - `feature.mov`: 2 min ProRes 1080p24 with stereo audio and changing imagery, so chapter thumbnails differ (for example `testsrc2` with `hue=H=t/10` and a sine).
   - `hlg.mov`: 15 s 10-bit ProRes tagged HLG (`setparams=color_trc=arib-std-b67:color_primaries=bt2020:colorspace=bt2020nc`).
   - `subs.srt`: three cues with é, ñ, ü, saved as Windows-1252.
   - `broken.mov`: 1 MB of random bytes.
   - `readonly/` with `chmod 555`.

## What to test

For each item, record what you did, what you expected and what happened.

1. **First launch.** Check the empty state, the sidebar defaults, and the toolbar: Add Files, Activity, Start. The Queue menu should list Start ⌘↩, Stop ⌘., Retry All and Clear Done, and File should have Add Files… ⌘O. Look at it in light and dark appearance. Open About Lacquer.
2. **Adding files.** Use Add Files… and drag from Finder onto the queue. Also use Finder › Open With › Lacquer. `broken.mov` should give one alert titled "This file wasn't added" with a plain-language reason. Adding a duplicate file does nothing.
3. **Rows.** Each row shows a disc icon, a source line ("1920×1080, 29.97 fps, 0:00:30 → 1080i29.97", with no thousands separators), a disc meter ("… of 25 GB, video at … Mbps"), and Format, Audio, Subtitles and Menu controls.
   - mono6 defaults to the 5.1 mono combination.
   - Forcing phone to 1080p/23.976 shows a 20% frame-drop warning.
   - HLG gets a tonemap note.
4. **Sidebar.** Changes apply to waiting rows at once, and they persist across relaunch.
5. **Subtitles.** Add `subs.srt` to `feature.mov` and set the language to Spanish.
6. **Menu designer.** Click Add Menu… on feature.mov. It should open in its own window titled "Menu for feature.mov".
   - Set the sidebar's chapters to "At times I list" with `0:00, 0:20, 0:40, 1:00, 1:20, 1:40` before opening the designer.
   - Try all three styles, the frame slider, a title and a subtitle line, and the TV safe areas toggle.
   - Name two scenes, and try a long name of about 40 characters.
   - Click buttons in the preview and use the arrow keys; the selection should move the way the layout suggests.
   - Close the window with Done. The row should read "Menu: <style>, “<title>”" with Edit… and Remove.
   - Open the designer for `hlg.mov`. Its stills should look normal, not washed out.
7. **Too long and output folder.** A read-only Save to folder should stop Start with one alert, without failing every job.
8. **Run, Stop, Retry, Quit.**
   - Set Save to `out/`. Run feature.mov with its menu as ISO and phone as BDMV.
   - Stop a job with ⌘.: it should say the partial disc was deleted, and `pgrep -fl "Lacquer.app/Contents/Resources/bin"` should show nothing. Then use Retry All.
   - Press ⌘Q while a job is encoding. Keep Encoding is the default button, and Quit leaves no ffmpeg running.
9. **Finished discs.** Check the Finder reveal and the log buttons. With ffprobe, confirm:
   - phone is 1080i (`field_order=tt`) with stereo AC-3 at 448 kbps;
   - mono6 has 6-channel AC-3;
   - feature has a PGS track tagged `spa`, and its ISO contains `NSR03` with a sensible volume label;
   - feature's disc has menu clips `BDMV/STREAM/01000.m2ts` and up.
10. **The menu, played.** Mount feature's ISO and open the mounted disc in VLC (`/Applications/VLC.app`, File › Open Disc… › Blu-ray, menus on). VLC plays Blu-ray menus through libbluray.
    - The menu should appear and match the designer's preview.
    - Move with the arrow keys and Enter. Play starts the film at 0:00.
    - Scenes opens the scene page, with your scene names. A scene button starts at its chapter.
    - Subtitles On and Off take effect when the film plays.
    - The Top Menu or Menu command returns to the menu.

    Screenshot each step. If VLC can't open the menu, try the BDMV folder output too, and record exactly what VLC shows.
11. **Visual review.** Look at every screenshot for clipped text, overlaps, uneven spacing, unclear wording for a filmmaker, and the designer window at its minimum size.

## Report

Write `~/Desktop/lacquer-gui-test-2/REPORT.md` with:
1. A one-paragraph verdict: is it ready for a public beta?
2. A defects table, most severe first, with columns #, severity (blocker / major / minor / cosmetic), area, steps, expected, actual, screenshot.
3. A pass/fail list for items 1–11.
4. Suggestions that aren't defects.

Report only what you observed. Say which steps you couldn't run and why.
