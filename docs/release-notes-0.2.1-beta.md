Lacquer 0.2.1 beta

Fixes from a code review after 0.2.0. If you made a disc with 0.2.0 from a master with separately timed mono tracks, or with a menu of about 18 pages or more as an ISO, make it again with this version.

Audio
- Discrete mono tracks that start at different times now stay in sync. Before, every track took the first track's offset.

Disc menus
- ISO output works with large menus, 100+ chapters and many scene pages. Before, it failed after the encode. Lacquer now checks the layout right after rendering the menu, before it encodes.
- Very long titles and subtitles end in an ellipsis instead of running off the frame or over the buttons.
- Menu backgrounds and chapter thumbnails from interlaced masters are deinterlaced, so there's no combing.
- The designer's busy indicator no longer sticks when you switch pages quickly.

Queue
- Two encodes of same-named masters into one folder can no longer pick the same output or delete each other's disc.
- Very long file names are shortened to fit, and the log is always written.
- Rows of running and finished jobs show the format the disc was actually made with.
- Adding the same file twice at the same moment makes one job.
- Quitting during an encode never waits more than ten seconds.

Command line (--headless --iso-from)
- An image written inside its own source folder no longer copies itself.
- A missing source folder is refused instead of producing a blank image.
- Long and non-Latin file names are stored correctly, and folders with many files work.
- --menu-loop rejects values that aren't finite or are out of range.

Known limits
- libbluray, the library VLC uses, has checked the menus and discs, but no hardware player has played them yet. Burn one disc and test it on your player before a duplication run.
- In VLC, a menu button pressed while playback is paused waits until you resume, and any presses you made while it was paused are ignored. Press Play again after resuming.
- No E-AC-3, TrueHD or DTS audio, because those formats need licences.
- No Intel build.

Files
- Lacquer-0.2.1-arm64.dmg: the app, signed and notarized.
- Lacquer-0.2.1-source.tar.gz: corresponding source for the app and the bundled FFmpeg, x264, zimg and tsMuxeR, with the build scripts.
- SHA256SUMS

SHA-256: `REPLACE_WITH_DMG_HASH`
