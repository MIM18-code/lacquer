I would not ship this beta unchanged. Review of main at `aafce81aded88989a65bcd4332d4f8fbb266b389` confirmed 15 additional defects, including deletion of another encode's finished output, incorrect synchronization of separately timed mono tracks, and failure to image otherwise working menus with many chapters. The build and all 81 tests pass, and ordinary menus work through libbluray, but those checks miss the failures below. No standalone hardware player was available, so this review does not certify hardware compatibility. No source files were changed, and findings listed as fixed in the earlier reviews are excluded.

Commands below run from the repo root. `R=/tmp/lacquer-review2.7oVDo1` and `S=/tmp/lacquer-state-review.B6RkbB` refer to the temporary fixtures and reproduction harnesses left by this review. Set `DISC_TOOLS_DIR="$PWD/packaging/vendor/runtime/bin"` for input-encoding commands. The harness builder compiles the current source files into temporary executables; it does not edit the repository.

**1. Major: canceling one concurrent encode can delete another run's finished disc**

Location: `Sources/Lacquer/EncodePipeline.swift:203`, `Sources/Lacquer/EncodePipeline.swift:311`, `Sources/Lacquer/EncodePipeline.swift:374`; `Sources/Lacquer/BDMVAuthor.swift:76`.

Defect and scenario: output naming checks whether a stem exists without reserving it atomically. Simultaneous app/headless or headless/headless runs for masters with the same basename can both select the same target and log. BDMV authoring removes an existing target, and unsuccessful pipeline cleanup removes that target without checking which run owns it. One run can finish successfully and then lose its entire disc when the other is stopped.

Confirmation: `python3 "$S/build_harness.py" RaceCancelAudit` runs two actual pipelines, synchronizes them at the checking callback, and pauses the second at the video stage while the first finishes. All three trials, also independently rerun, printed `first result success(...)`, `exists before cancel: true`, `second result failure(Swift.CancellationError())`, and `exists after cancel: false`. `RaceAudit` additionally reproduced missing tsMuxeR meta files and two successful runs returning the same output path.

Fix: reserve the output stem with an atomic filesystem operation before encoding. Authoring and cleanup must remove only outputs owned by that reservation.

**2. Major: discrete mono tracks with unequal start times become misaligned**

Location: `Sources/Lacquer/BluRayEncoder.swift:344`.

Defect and scenario: the discrete-audio graph joins samples first, then applies only the first track's start offset to the joined program. A left track beginning at zero and a right track beginning one second later lose their relative offset. The same problem affects separately timed 5.1 channels. The earlier common-offset regression does not cover unequal offsets between tracks.

Confirmation: generated `mono-offset.mov` with three seconds of picture and silent left audio, plus a two-second right-channel sine starting at one second:

```sh
packaging/vendor/runtime/bin/ffmpeg -v error -y \
  -f lavfi -i color=c=gray:s=320x180:r=24:d=3 \
  -f lavfi -i anullsrc=r=48000:cl=mono:d=3 \
  -itsoffset 1 -f lavfi -i sine=frequency=1000:sample_rate=48000:duration=2 \
  -map 0:v -map 1:a -map 2:a -c:v libx264 -preset ultrafast \
  -c:a pcm_s16le "$S/mono-offset.mov"
.build/debug/Lacquer --headless --input "$S/mono-offset.mov" \
  --output-dir "$S/output" --mode m2ts --one-pass --chapters none
```

ffprobe reports the mono streams starting at `0.000000` and `1.000000`. The encode succeeds and automatically selects joined stereo. Decoding its AC-3 to signed 16-bit PCM and measuring 0.2–0.5 seconds gives right-channel RMS `2895.6656`, although that channel should still be silent; left-channel RMS is `0.7081`. The right-channel tone moved one second early.

Fix: pad or trim each mono input against the video start and reset its timestamps before joining. Do not derive synchronization for the whole joined program from its first input.

**3. Major: metadata reservation prevents ISO output for valid menus with many chapters**

Location: `Sources/Lacquer/Menus/UDFImageWriter.swift:168`, `Sources/Lacquer/Menus/UDFImageWriter.swift:307`; `Sources/Lacquer/EncodePipeline.swift:496`.

Defect and scenario: metadata capacity is calculated from content bytes alone. Each directory consumes two metadata sectors, each file another sector, and every menu page adds five files including backups. A short title with many chapters can exhaust metadata despite ample disc space. The app discovers this only after rendering and encoding every menu page.

Confirmation: generated a 12-second 23.976 fps master with bundled ffmpeg, then authored 100 custom chapters at 0.1-second intervals:

```sh
.build/debug/Lacquer --headless --input "$R/film.mov" \
  --output-dir "$R/many100" --mode bdmv --one-pass \
  --chapters "$(cat "$R/chapters100.txt")" --menu fullFrame
Scripts/menu-check/menu_check "$R/many100/film_BluRay" \
  --map "$R/many100/film_BluRay.menu.json"
.build/debug/Lacquer --headless --iso-from "$R/many100/film_BluRay" \
  --output "$R/many100.iso"
```

The BDMV has 100 chapter marks and 18 menu pages; the harness reports `ALL PASSED: 193 passed, 0 failed`. Imaging that folder fails with `The disc image can't hold this layout: not enough metadata space`. The complete app pipeline with 217 chapters and `--mode iso --menu titleCard` likewise encoded all 38 menu pages before returning the same error.

Fix: size metadata from the complete directory/file tree, required descriptors, and directory data, rather than a bytes-per-disc heuristic. Calculate and validate layout capacity before the long encode.

**4. Major: an ISO inside its source folder can become an unbounded self-copy**

Location: `Sources/Lacquer/Menus/UDFImageWriter.swift:118`, `Sources/Lacquer/Menus/UDFImageWriter.swift:143`, `Sources/Lacquer/Menus/UDFImageWriter.swift:161`, `Sources/Lacquer/Menus/UDFImageWriter.swift:240`.

Defect and scenario: a second invocation of `--iso-from Disc --output Disc/disc.iso` enumerates the old output as an input file. Initialization then deletes that image and recreates it at the same path. When `addFile` reaches that path, it reads the image currently being written and appends those bytes to itself, continually moving EOF. The previous image is destroyed and the replacement can fill the drive.

Confirmation: with a five-byte file under `$R/selfimage/BDMV/AUXDATA`, the first invocation of `.build/debug/Lacquer --headless --iso-from "$R/selfimage" --output "$R/selfimage/disc.iso"` succeeded. The identical second invocation did not finish. A Python subprocess watchdog killed it after 0.3 seconds; the new image had already grown to `640927744` bytes. The watchdog test removed that temporary image afterward.

Fix: exclude the destination by resolved filesystem identity, including symlink aliases, and reject any input file that aliases the output. Write through a temporary image and replace the destination only after successful completion.

**5. Minor: the ten-second quit timeout does not actually bound waiting**

Location: `Sources/Lacquer/LacquerApp.swift:129`; `Sources/Lacquer/EncodeCoordinator.swift:228`.

Defect and scenario: leaving `withTaskGroup` waits for all children even after `cancelAll`. The `stopAndWait` child awaits `runTask.value`, which does not stop waiting when that child is canceled. Cleanup stalled on an external or network volume can therefore hold Quit indefinitely instead of reaching the advertised ten-second fallback.

Confirmation: by reading the actual quit and coordinator paths, plus `python3 "$S/build_harness.py" quit`, a shortened reproduction of the same task-group structure. Its 100 ms timeout fired at `0.1063` seconds, but the reply was not reached until the one-second work task completed at `1.0326` seconds. Normal subprocess cancellation is not the defect here; the fallback deadline is ineffective.

Fix: use a timeout mechanism whose losing waiter cannot hold structured group completion. After the deadline, reach the termination reply and force subprocess termination without waiting indefinitely for cleanup.

**6. Minor: a directory overflow crashes before the writer's bounds check**

Location: `Sources/Lacquer/Menus/UDFImageWriter.swift:372`, `Sources/Lacquer/Menus/UDFImageWriter.swift:399`, `Sources/Lacquer/Menus/UDFImageWriter.swift:682`.

Defect and scenario: directory identifiers are written into a fixed 2048-byte array, and the directory-size guard runs only after all writes. An imported folder with enough entries traps in the byte writer instead of reporting an unsupported layout. This is separate from the metadata-reservation failure above.

Confirmation: created `$R/udf-many/BDMV/PLAYLIST` containing 40 files named `00000.mpls` through `00039.mpls`. `SWIFT_BACKTRACE=enable=no .build/debug/Lacquer --headless --iso-from "$R/udf-many" --output "$R/udf-many.iso"` exits `133` with `Swift/ContiguousArrayBuffer.swift:705: Fatal error: Index out of range`. The intended `tooManyEntries` check never executes.

Fix: calculate directory identifier sizes before writing and allocate the required sectors, or reject the layout before any buffer access. The byte writer should throw on a capacity overrun rather than subscript beyond its allocation.

**7. Minor: UDF file identifiers truncate Unicode names and crash on valid long names**

Location: `Sources/Lacquer/Menus/UDFImageWriter.swift:387`, `Sources/Lacquer/Menus/UDFImageWriter.swift:656`, `Sources/Lacquer/Menus/UDFImageWriter.swift:669`.

Defect and scenario: file-identifier storage is sized from UTF-8 byte count, then encoded using Latin-1 or UTF-16BE. Those encodings require different lengths. The result can truncate a source filename and count padding as part of its identifier. A valid 255-byte ASCII filename also produces a 256-byte encoded identifier, which traps at `UInt8(length)`.

Confirmation: created `BDMV/AUXDATA/中.txt` in `$R/unicode`, then ran `.build/debug/Lacquer --headless --iso-from "$R/unicode" --output "$R/unicode.iso"`. It reported success. Reading the image with Homebrew libudfread listed the file as `中.t`; opening `BDMV/AUXDATA/中.txt` failed. Direct byte inspection found `104e2d002e007400...`, confirming the missing `xt`. A second fixture containing an ASCII filename of 255 `a` characters exited `133` with `Fatal error: Not enough bits to represent the passed value` during imaging.

Fix: encode file identifiers first and use their actual encoded length, without d-string padding or a trailing d-string length byte. Validate the one-byte identifier-length limit and throw before any narrowing conversion.

**8. Minor: a nonexistent image source produces a successful blank ISO**

Location: `Sources/Lacquer/Menus/UDFImageWriter.swift:118`; `Sources/Lacquer/HeadlessCLI.swift:42`.

Defect and scenario: failure to enumerate the source is treated as an empty file list. A typo in `--iso-from`, or passing an ordinary file as the source, writes an empty filesystem and reports success instead of refusing the missing disc.

Confirmation: `.build/debug/Lacquer --headless --iso-from "$R/does-not-exist" --output "$R/missing-folder.iso"` exited zero and printed `output: .../missing-folder.iso`. `Scripts/menu-check/menu_check "$R/missing-folder.iso" --map "$R/normal/film_BluRay.menu.json"` failed immediately with `FAIL libbluray opens ...`.

Fix: require a readable source directory and the required BDMV files before creating the destination. Propagate enumeration errors rather than treating them as an empty disc.

**9. Minor: long source names exceed output-name limits and silently lose logs**

Location: `Sources/Lacquer/EncodePipeline.swift:205`, `Sources/Lacquer/EncodePipeline.swift:335`; `Sources/Lacquer/RunLogger.swift:35`.

Defect and scenario: output naming appends `_BluRay`, the output extension, and sidecar extensions without budgeting for the filesystem's filename limit. A legal source name can yield an illegal log or ISO name. Logger creation errors are ignored, so a successful BDMV can claim to have a log that was never written; ISO output fails only after encoding finishes.

Confirmation: copied the 12-second fixture to a name consisting of 247 `x` characters plus `.mov`. `.build/debug/Lacquer --headless --input "$(cat "$R/long-input.txt")" --output-dir "$R/longname" --mode bdmv --one-pass --chapters none` succeeded and printed its log URL. The output directory contained only the 254-byte-named BDMV folder, with no `.log` file. The same command with `--mode iso --output-dir "$R/longname-iso"` completed video and audio before failing with tsMuxeR exit `255`, `Can't create output file ..._BluRay.iso`; its promised log was also absent.

Fix: truncate stems on character boundaries to a byte budget that reserves space for numbering and the longest output/sidecar suffix. Make log creation failure explicit before starting the encode.

**10. Minor: very long menu titles exceed their layout bounds**

Location: `Sources/Lacquer/Menus/MenuCanvas.swift:346`; `Sources/Lacquer/Menus/MenuPlanner.swift:193`, `Sources/Lacquer/Menus/MenuPlanner.swift:210`.

Defect and scenario: `TypeBlock.fitting` stops shrinking at the minimum font size and returns the block even when it still exceeds `maxLines` and `maxHeight`. The designer accepts unlimited title and subtitle text. Long text can disappear above the frame or extend across the menu buttons in the authored disc.

Confirmation: compiled the actual planner, canvas, style, template, and contract sources with `$R/main.swift`, then ran `$R/geometry`. With `String(repeating: "This film has a very long title ", count: 40)`, Full Frame returned 22 lines at 56 px, with title bounds starting at `y=-442.87`. Title Card returned 40 lines at 52 px, with bounds `y=-683.0`, height `2335.84`, intersecting buttons. Typographic returned 30 lines at 56 px, height `1658.27`, also intersecting buttons. No fitter error or truncation was applied.

Fix: truncate or ellipsize to the requested line and height limits once the minimum font size is reached, or reject text that cannot fit. Apply the same policy to the subtitle block.

**11. Minor: interlaced masters produce combed progressive menu stills**

Location: `Sources/Lacquer/Menus/MenuRenderer.swift:81`; `Sources/Lacquer/Menus/HDMVMenuAuthor.swift:299`.

Defect and scenario: frame grabbing scales and optionally tonemaps, but does not deinterlace. Moving edges in a 1080i or DV master retain their alternating temporal fields in backgrounds and chapter thumbnails. Those images are subsequently encoded as progressive menu video, so the player cannot recover the original field motion.

Confirmation: generated a 1920×1080 BFF fixture from alternating white/black 50 fps frames, then ran the renderer's exact grab filter:

```sh
packaging/vendor/runtime/bin/ffmpeg -hide_banner -loglevel error -y \
  -ss 0.600 -i "$S/menu-interlaced.mov" -an -sn -dn -frames:v 1 \
  -vf 'scale=w=trunc(iw*sar/2)*2:h=ih,setsar=1,scale=1920:1080:force_original_aspect_ratio=decrease:flags=lanczos' \
  "$S/menu-interlaced-grab.png"
```

ffprobe identifies the source as `field_order=bb`. Decoding the PNG to gray pixels gives its first 20 row means as `[255, 0, 255, 0, ...]`, independently measured, demonstrating that the separate fields remain woven into the progressive still.

Fix: apply an automatic deinterlacer to interlaced inputs before tonemapping and scaling menu frames. Use the same corrected frame path for the designer and chapter thumbnails.

**12. Minor: switching back to a cached designer page can leave the busy indicator stuck**

Location: `Sources/Lacquer/Menus/MenuDesignerView.swift:486`, `Sources/Lacquer/Menus/MenuDesignerView.swift:499`, `Sources/Lacquer/Menus/MenuDesignerView.swift:508`.

Defect and scenario: cancellation during synchronous page composition can reach the early return at line 499 and skip clearing `isRendering`. A replacement refresh for an already cached page returns before touching that flag. Selecting Main Menu while Scenes is composing can leave the spinner on even though the cached main page is displayed and no render remains.

Confirmation: `python3 "$S/build_harness.py" DesignerAudit` extracts the actual model unchanged and compiles it with the actual renderer sources. It caches page zero, starts page one, then cancels that request and returns to cached page zero. Both the initial run and an independent rerun printed `return to cached page after ms 400 before true after true page 0`; the defect also reproduced at 500, 600, 800, and 1000 ms. Cancellation at 300 ms, while still in frame grabbing, cleared the flag correctly.

Fix: clear rendering state in a generation-aware `defer` covering every exit. A cached replacement request must also retire the previous request's busy state.

**13. Minor: overlapping file additions bypass duplicate suppression**

Location: `Sources/Lacquer/EncodeCoordinator.swift:94`.

Defect and scenario: `loadInput` checks for an existing job before awaiting ffprobe, then appends without checking again. Opening a master through the Dock/Open With and adding the same file through a drop or picker while probing is still underway can queue it twice, causing an unintended second encode.

Confirmation: `python3 "$S/build_harness.py" StateAudit` calls the actual coordinator's `loadInput` concurrently for the same source. Both the original run and an independent rerun printed `jobs: 2 distinct source paths: 1`.

Fix: track in-flight input URLs or repeat the duplicate check immediately before appending, on the main actor.

**14. Minor: running and completed rows can claim the wrong video format**

Location: `Sources/Lacquer/ContentView.swift:598`, `Sources/Lacquer/ContentView.swift:674`; `Sources/Lacquer/Models.swift:612`; `Sources/Lacquer/EncodeCoordinator.swift:264`.

Defect and scenario: the pipeline snapshots the video standard when a job starts, but the job stores only its started output mode. Its row continues deriving the displayed video standard from the current sidebar settings. Changing Format to 1080p24 relabels a completed 1080i25 disc as 1080p24; the same false label can appear during an encode.

Confirmation: by reading the snapshot, job model, and row rendering paths. A job without a per-job standard override resolves the row's `standard` from `settings.videoStandard` even when its status is running or done. There is no stored started standard to consult.

Fix: store the started video standard alongside `startedOutputMode` and display it for jobs that have started. Clear that snapshot on retry.

**15. Minor: an infinite or excessive menu-loop duration crashes after film authoring**

Location: `Sources/Lacquer/HeadlessCLI.swift:134`; `Sources/Lacquer/Menus/HDMVMenuAuthor.swift:216`.

Defect and scenario: the CLI accepts `Double("inf")` and excessively large finite values for `--menu-loop`. After encoding and muxing the film, the author converts that duration to an `Int` frame count and traps. The crash skips pipeline cleanup and leaves the partial disc.

Confirmation: `.build/debug/Lacquer --headless --input "$R/film.mov" --output-dir /tmp/lacquer-menu-binary-review --mode bdmv --one-pass --menu-demo --menu-loop inf` exited `133` with `Fatal error: Double value cannot be converted to Int because it is either infinite or NaN`. The log reached `Menu: 2 page(s), film has 1 chapter mark(s), 0 subtitle stream(s)` after film muxing. The partial `film_BluRay` folder remained.

Fix: reject nonfinite and out-of-range durations in CLI parsing before encoding, and validate the contract again in the author before numeric conversions. Bound durations by the frame-count and timestamp fields they must fit.

**Checked and found correct**

- `swift build -Xswiftc -warnings-as-errors` initially hit a sandbox denial for the global Clang cache. It passed with `CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" swift build --disable-sandbox -Xswiftc -warnings-as-errors`. `swift test --disable-sandbox` with those same cache variables passed all 81 tests in 40.129 seconds. SwiftPM's inaccessible global-cache warnings are environmental, not app defects.
- Built `Scripts/menu-check/menu_check` with `Scripts/menu-check/build.sh`. A Title Card BDMV with six chapters and subtitles passed 23 checks, and its directly written ISO passed the same 23. A Typographic BDMV with no chapters or subtitles passed nine. The 100-chapter Full Frame BDMV passed 193. A 25 fps silent master authored through the complete menu ISO pipeline passed nine, with the film encoded as 1080i25. These cover page entry, remote edges, chapter starts, subtitle toggles including rapid activation, Top Menu, and loop selection retention.
- Inspected menu transport bytes: 192-byte packets and 6144-byte clip alignment, expected PIDs, increasing arrival timestamps, no continuity errors, matching PES/IG segment lengths, and maximum PCR spacing of 70.059 ms. The generated menu background is 1920×1080 progressive H.264, level 4.1, 24000/1001 fps, with stereo AC-3. CLPI coarse/fine entries, MPLS fields, navigation command encodings, and index/movie-object layouts were checked against the local libbluray and tsMuxeR reference sources. No additional hardware-spec violation was confirmed.
- Wrote an ISO containing a `4294971392`-byte file and read it with libudfread. Its full size and six markers around the 1 GiB extent boundary, 4 GiB boundary, and EOF were correct. Direct inspection found `NSR03` and UDF revision bytes `50 02`; the completed image was `4296736768` bytes. An image exceeding `2^32` sectors would exceed 8 TiB and both supported Blu-ray capacities; that size was not physically generated or certified.
- Read the menu planner, renderer, palette, every binary writer, author/pipeline wiring, ProcessRunner, coordinator, designer model, and remaining source paths relevant to data loss or incorrect output. Cancellation before subprocess launch and stopping during the start delay are handled; retry preserves intended per-job settings. The tested BFF film encode retained temporal field order. The previously fixed anamorphic, common audio-offset, attached-picture, and short-clip defects were not re-reported.
- No hardware playback, optical burn, mount-based validation, packaging build, commit, or push was performed. IG timeout semantics and hardware decoder-buffer/HRD behavior remain outside the confirmed findings; passing libbluray does not establish those properties.
