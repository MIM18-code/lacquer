# GUI re-test for Lacquer 0.2.0 build 2 (prompt for Codex with computer use)

Paste everything below the line into Codex. It re-checks the five findings from `~/Desktop/lacquer-gui-test-2/REPORT.md` on the fixed build, then does a short regression sweep.

---

Re-test the Mac app Lacquer through its real GUI, using computer use. Your previous pass (`~/Desktop/lacquer-gui-test-2/REPORT.md`) found five defects. They've been fixed in build 2. Confirm each fix, look for anything the fixes broke, and report.

## Ground rules

- Report only. Don't edit the repo (`~/Documents/Blu Ray Compression App`), commit, push or publish.
- Work under `~/Desktop/lacquer-gui-test-3/` with `out/` and `shots/` inside. Reuse the fixtures in `~/Desktop/lacquer-gui-test-2/fixtures/`. Save a screenshot for every step you cite.
- If your computer-use helper can't read a window, record the exact error once and move on.
- Unmount any ISO you mount (`hdiutil detach`) and quit VLC when you're done.

## Install

Mount `~/Documents/Blu Ray Compression App/packaging/dist/Lacquer-0.2.0-arm64.dmg`, replace `/Applications/Lacquer.app` with it, eject, and open it. Check that About Lacquer says version 0.2.0 (2). Confirm with `codesign -dv /Applications/Lacquer.app 2>&1 | grep -i team` and `spctl -a -vv /Applications/Lacquer.app`.

## The five fixes

1. **Designer at minimum size.** Open Add Menu… on `feature.mov` and shrink the designer window as small as it will go. Everything should stay inside the window and usable at that size: the preview, the page picker, every settings field, and Done. Then enlarge it again.
2. **Subtitles Off in VLC.** Set chapters to `0:00, 0:20, 0:40, 1:00, 1:20, 1:40`. Add `subs.srt` (Spanish) and a Title Card menu to `feature.mov`. Write an ISO to `out/`, mount it, and open it in VLC with File › Open Disc › Blu-ray, menus on. Run the sequence that failed last time: Subtitles On → Play (a cue should appear by about 5 s) → Top Menu → Subtitles Off → Play. Cues must stay hidden at about 5 s and 22 s. Then try Off → Play quickly, and once while VLC is paused. A quick second press may be ignored (the button is animating), which is expected: press Play again if nothing happens. What must not happen is subtitles showing after Off. Then check that Subtitles On still turns them back on.
3. **Write setting right before Start.** Add `phone.mp4` with Write set to ISO image. Switch Write to BDMV folder and immediately press ⌘↩. The row's source line should name the output ("→ 1080i29.97, BDMV folder" before Start, then whatever it is actually writing once running). The finished output should match what the row said while running. Repeat a couple of times. Report any case where the finished output differs from the row's label.
4. **⌘O.** With Lacquer frontmost, press ⌘O. The Add Files panel should open. Try it again after clicking a queue row and after typing in a sidebar field.
5. **Extreme frame rates.** Add `~/Desktop/lacquer-gui-test-2/fixtures/too_long.mov` if it still exists (otherwise make a 3-frame, 60-hour MOV). The frame-rate warning should be a plain sentence about an unusual frame rate, not a huge percentage. Remove the row afterwards.

## Regression sweep (quick)

- Add mono6, phone and hlg. Check that rows show the right defaults: 5.1 from mono tracks, 1080i29.97 for phone, a tonemap note for hlg. The disc meter should read "… of 25 GB".
- The menu designer: switch styles, name a scene, and use the arrow keys in the preview. Done gives the row summary.
- ⌘. stops a running job and its partial output is deleted. Retry All re-queues it. ⌘Q during an encode defaults to Keep Encoding, and Quit leaves no `ffmpeg` (`pgrep -fl "Lacquer.app/Contents/Resources/bin"`).
- In VLC, the menu still matches the designer, Play starts at 0:00, a Scenes button starts at its chapter, and Top Menu returns.
- Look at the main window in light and dark.

## Report

Write `~/Desktop/lacquer-gui-test-3/REPORT.md`:
1. A verdict: ready for public beta, yes or no, and why.
2. Each of the five fixes as fixed / not fixed / partly fixed, with evidence.
3. Any new defects, in a table with columns severity, steps, expected, actual, screenshot.
4. Regression sweep pass/fail.
5. Steps you couldn't run, and why.
