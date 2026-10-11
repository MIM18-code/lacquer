Lacquer 0.2.0 beta

Lacquer turns a finished film master into a Blu-ray: a BDMV folder, a UDF 2.50 disc image ready for a duplicator, or an M2TS for Toast. You can add an on-screen menu too. This is the first public release. It's free and open source under GPL-3.0, and runs on Apple Silicon Macs with macOS 13 or later.

What it does
- Picks the Blu-ray format that keeps every frame of your master. 25 and 29.97 fps go on the disc as 1080i carrying whole frames, and the queue warns you if a format you choose would drop or repeat frames.
- Handles the audio layouts editors export. Lacquer uses a 5.1 track as is and combines six separate mono tracks into 5.1, in SMPTE or film order. Audio is AC-3.
- Sets the bitrate to fill BD-25 or BD-50, and refuses a film that can't fit before encoding starts.
- Tonemaps HDR masters, converts SD color, and deinterlaces before scaling.
- Turns .srt files, including Windows-encoded ones, into subtitles viewers can switch on and off. Chapter stops land on exact frames.
- Adds disc menus in three styles: a background frame or poster, Play, scene pages with named chapters, and subtitles on and off. Navigation is real HDMV, so First Play and Top Menu work.
- Checks free space, the output folder and disc fit before encoding. Stop and Quit clean up after themselves, and every disc gets a log.

Known limits
- libbluray, the library VLC uses, has checked the menus and discs, but no hardware player has played them yet. Burn one disc and test it on your player before a duplication run.
- No E-AC-3, TrueHD or DTS audio, because those formats need licences.
- No Intel build.

Files
- Lacquer-0.2.0-arm64.dmg: the app, signed and notarized.
- Lacquer-0.2.0-source.tar.gz: corresponding source for the app and the bundled FFmpeg, x264, zimg and tsMuxeR, with the build scripts.
- SHA256SUMS

SHA-256: `915c3a6d5ef9e931457726c0e5fcf222b11c03e45e5dce6286db81a8451b37d5`
