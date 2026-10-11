# GUI test pass for Lacquer (prompt for Codex with computer use)

Paste everything below the line into Codex. It assumes the notarized DMG exists at `packaging/dist/Lacquer-0.2.0-arm64.dmg`; change the version if it has moved on.

---

Test the Mac app Lacquer through its real GUI, using computer use, and write up every defect you find. Lacquer turns a finished film master (ProRes, H.264, HEVC in MOV/MP4/MXF/MKV) into a Blu-ray: a BDMV folder, a UDF 2.50 ISO, or an M2TS. The repo is `/Users/joshualand/Documents/Blu Ray Compression App`; `README.md` describes what the app should do and `HANDOFF.md` lists recent changes. The encode logic already has unit tests and an end-to-end script (`Scripts/e2e_test.sh`). This pass is about what a person sees and clicks: layout, wording, state changes, error handling, and whether the files it writes match what the UI promised.

## Ground rules

- Don't edit anything in the repo, don't commit, don't push, and don't publish anything. Report only.
- Do all work under `~/Desktop/lacquer-gui-test/` (create it). Put fixtures in `fixtures/`, outputs in `out/`, screenshots in `shots/`.
- Use `/opt/homebrew/bin/ffmpeg` and `ffprobe` to make fixtures and inspect outputs. Use the bundled tools at `/Applications/Lacquer.app/Contents/Resources/bin/` only to inspect, not to make fixtures.
- Encodes of the short fixtures take under a minute each. Don't wait on anything longer than 5 minutes; if something hangs, record it as a defect, quit the app, and continue.
- Take a screenshot at every state named below and save it with a descriptive name.

## Setup

1. Mount the DMG, check the window shows Lacquer and an Applications shortcut, drag Lacquer into Applications, eject. First launch from /Applications must open with no Gatekeeper warning. Record what you see.
2. Make these fixtures:
   - `mono6.mov`: 30 s ProRes 1080p23.976 with six separate mono PCM tracks (sine 220, 330, 440, 60, 550, 880 Hz; that order is L R C LFE Ls Rs).
   - `phone.mp4`: 30 s H.264 1080p29.97 with stereo AAC.
   - `pal50.mov`: 20 s H.264 1080p50, no audio.
   - `hlg.mov`: 15 s 10-bit ProRes tagged HLG (`setparams=color_trc=arib-std-b67:color_primaries=bt2020:colorspace=bt2020nc`).
   - `long title with a "quote" in it and quite a lot of extra words.mov`: 10 s 720p24 H.264.
   - `marathon.mkv`: 60 hours of 64×64 black at 1 fps (`-c:v libx264 -preset ultrafast`); too long for any disc.
   - `subs.srt`: three cues with accented text (é, ñ, ü), saved as Windows-1252, not UTF-8.
   - `broken.mov`: 1 MB of random bytes.
   - A folder `reels/` holding two copies of `phone.mp4` named `reel1.mp4` and `reel2.mp4`.
   - A folder `readonly/`, then `chmod 555` it.

## What to test

For each item, write what you did, what you expected, and what happened.

1. **First launch.** Empty-state wording, sidebar defaults, window minimum size (drag it smaller), light and dark appearance (switch in System Settings › Appearance). About Lacquer from the app menu: does it show the version, license text, and does the third-party notices link open?
2. **Adding files three ways.** Choose Files… (pick `mono6.mov` and `phone.mp4`), drag `hlg.mov` and the `reels/` folder from Finder onto the drop zone, and right-click `pal50.mov` in Finder › Open With › Lacquer. All should appear in the queue. Then add `broken.mov`: you should get one clear alert naming the file, and no queue row for it. Add the same file twice: it shouldn't be duplicated.
3. **Per-job details.** For each row, check the summary line (source size, rate, duration, → target format, bitrate, disc, size estimate) and any notes under it:
   - `mono6.mov` defaults to "Mono tracks 1–6 as 5.1 (L R C LFE Ls Rs)". The audio menu also offers the film-order 5.1, stereo, and each single track. Picking a single mono track should show an orange warning.
   - `phone.mp4` goes to 1080i29.97 with no frame-rate warning. Change its Format to 1080p / 23.976: an orange warning about dropping about 20% of frames should appear. Set it back to Match source.
   - `pal50.mov` goes to 1080i25 and notes the silent audio track.
   - `hlg.mov` notes it'll be tonemapped to SDR.
4. **Sidebar applies to pending jobs.** Switch Disc to BD-50, Audio to 448, and Video to a fixed format. Every pending row's summary should update right away. Quit and relaunch: settings should be remembered. Put them back afterwards (BD-25, 640, Match each source).
5. **Subtitles.** Add `subs.srt` to `phone.mp4`, set the language to Spanish, then remove it and add it again.
6. **Too long.** Add `marathon.mkv`. Its row should show a red notice saying it won't fit and suggesting BD-50 or 448 kbps. Switch Output to M2TS: the notice should go away. Switch back to BDMV and remove the row.
7. **Output folder.** Choose `readonly/` as Save to, start the queue, and confirm the first job fails quickly with a message about not being able to write there, not after encoding. Then choose `out/`.
8. **Run, stop, retry.** Set Output to ISO. Start the queue. While a job is encoding, check the progress bar, percentage and time-left text. Press Stop: the job should say it stopped and that partial output was deleted, there should be no leftover `.iso` in `out/`, and `pgrep -fl "Lacquer.app/Contents/Resources/bin"` should print nothing. Press Retry on it and Start again.
9. **Quit while encoding.** Start a job, press ⌘Q: a confirmation should appear. Choose Keep Encoding and confirm it continues. Press ⌘Q again and choose Quit: afterwards, `pgrep` as above must print nothing.
10. **Finished jobs.** Let the remaining queue finish (relaunch and re-add if needed). For each Done row, the folder button should reveal the output in Finder and the log button should open its `.log`. Clear Done should remove only finished rows. Expand Activity and check it scrolls to the newest line.
11. **Check what was written.** For each output, use ffprobe (mount ISOs with `hdiutil attach -readonly`) and confirm:
    - the video is H.264 at the format the row promised;
    - 1080i outputs report `field_order=tt`;
    - `mono6` has 6-channel AC-3 with the 440 Hz tone on the centre channel and 60 Hz on LFE (`astats` zero-crossing rate per channel works);
    - `phone` has stereo AC-3 at 448 kbps;
    - outputs from sources without audio have a stereo AC-3 track;
    - `phone` with subs has a PGS subtitle stream tagged `spa`;
    - ISOs contain `NSR03` (`LC_ALL=C grep -a -c NSR03 file.iso`) and mount with a volume label derived from the file name;
    - the quote in the long filename became an apostrophe in the output name.
12. **Visual review.** Look at every screenshot for clipped or truncated text that hides meaning, controls that overlap, inconsistent spacing, things that look clickable but aren't, and wording that's unclear to a filmmaker who doesn't know Blu-ray jargon.

## Report

Write `~/Desktop/lacquer-gui-test/REPORT.md`:

1. A one-paragraph verdict: is this ready for a public beta?
2. A defects table, most severe first, with these columns:
   - **#**
   - **Severity:** blocker / major / minor / cosmetic
   - **Area**
   - **Steps to reproduce**
   - **Expected**
   - **Actual**
   - **Screenshot**
3. A pass/fail list for items 1–12.
4. Wording or layout suggestions that aren't defects, kept separate from the defects.

Report only what you saw happen. If you couldn't run a step, say so and why. Don't guess at causes in the code unless you read the code to confirm.
