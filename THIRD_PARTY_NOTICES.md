# Third-party notices

This app is licensed under the GNU General Public License, version 3 (see
`LICENSE`). It runs three separate command-line programs, bundled in
`Contents/Resources/bin/`. Their license texts, the exact build commands and
the SHA-256 of every source archive are in `Contents/Resources/legal/`.

| Program | Version | License | Role |
| --- | --- | --- | --- |
| FFmpeg (`ffmpeg`, `ffprobe`) | 9.0.2 | GPL-3.0-or-later (built with `--enable-gpl --enable-version3`) | decode masters, scale, filter, encode AC-3 |
| x264 (linked into `ffmpeg`) | stable branch, commit `b35605ac` | GPL-2.0-or-later | H.264 encoder |
| zimg (linked into `ffmpeg`) | 3.0.6 | WTFPL v2 | `zscale` filter for HDR to SDR tone mapping |
| tsMuxeR | 2.7.0 | Apache-2.0 | mux H.264 and AC-3 into Blu-ray M2TS |
| libpng (statically linked into `tsMuxeR`) | 1.6.47 | libpng License (PNG Reference Library License v2) | PNG input for subtitle rendering |
| FreeType (statically linked into `tsMuxeR`) | not recorded by upstream | FreeType License (FTL) | text subtitle rendering |

x264 and zimg are libraries linked into `ffmpeg` and `ffprobe`; they are not
separate programs.

FFmpeg and x264 are combined into one executable, so that executable is
distributed under GPL-3.0-or-later. tsMuxeR is a separate program that the app
starts as a child process; Apache-2.0 is compatible with GPL-3.0.

## Source code

The corresponding source for everything above is published with each release
as `<name>-<version>-source.tar.gz`. It holds this app's source, the
unmodified upstream archives listed below, and the scripts in `packaging/` that
build them. The archive hashes are pinned in `packaging/runtime-sources.json`
and checked before every build. No upstream source was patched.

| Component | Archive | SHA-256 |
| --- | --- | --- |
| FFmpeg 9.0.2 | `ffmpeg-9.0.2.tar.xz` from https://ffmpeg.org/releases/ | `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e` |
| x264 | `x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55.tar.gz` from https://code.videolan.org/videolan/x264 | `cd71a7515b0e9a012e1ac9b1f8415bebcaf6fc97d4db32286642ac4c0fbe24f9` |
| zimg 3.0.6 | `zimg-release-3.0.6.tar.gz` from https://github.com/sekrit-twc/zimg | `be89390f13a5c9b2388ce0f44a5e89364a20c1c57ce46d382b1fcc3967057577` |
| tsMuxeR 2.7.0 source | `tsMuxer-2.7.0-source.tar.gz` from https://github.com/justdan96/tsMuxer | `9ec281325ed5e2083720f0aa8ab628b5da4f97e215466d77b42ac965bc8c3ea7` |
| libpng 1.6.47 | `libpng-1.6.47.tar.gz` from https://github.com/pnggroup/libpng (license text and source) | `631a4c58ea6c10c81f160c4b21fa8495b715d251698ebc2552077e8450f30454` |
| tsMuxeR 2.7.0 binary | `tsMuxer-2.7.0-mac.zip` from https://github.com/justdan96/tsMuxer/releases/tag/2.7.0 (unmodified, arm64) | `bf90b608321f491b955fd9432000a8370c048e9c306e3a5833dfd75e5fa530e1` |

The FFmpeg signature (`ffmpeg-9.0.2.tar.xz.asc`, SHA-256
`d617fd94ea354dadd2a8bb16243d37c44e1e9729b06b6ad58fe30bfb0fa943f2`) and the
signing key (`ffmpeg-devel.asc`, SHA-256
`397b3becedcd5a98769967ff1ff8501ddc89f8368b8f766e4701377d7dbaabe5`, fingerprint
`FCF9 86EA 15E6 E293 A564 4F10 B432 2F04 D676 58D8`) are pinned too. The build
checks the signature with gpg when gpg is installed.

To rebuild the tools on Apple Silicon with Xcode command line tools,
autoconf, automake, libtool and pkg-config installed:

    python3 packaging/prepare_runtime.py --force

## FFmpeg

Copyright (c) the FFmpeg developers. Licensed under the GNU General Public
License version 3 or later because the build enables GPL components
(`--enable-gpl`, `--enable-version3`). License texts: `legal/ffmpeg/`.
Project page: https://ffmpeg.org/

Configure line:

    ./configure --prefix=<prefix> --cc=clang --arch=arm64 --enable-static --disable-shared \
      --disable-autodetect --enable-gpl --enable-version3 --enable-libx264 --enable-libzimg \
      --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib --enable-iconv \
      --disable-network --disable-doc --disable-ffplay --disable-debug \
      --pkg-config-flags=--static --extra-libs="-lc++ -liconv"

Compiler and linker flags also set `-mmacosx-version-min=13.0`. The complete
line as run is in `legal/BUILD.txt`. The build links only Apple system
libraries (`/usr/lib`, `/System/Library`): VideoToolbox and AudioToolbox for
hardware-assisted decode, plus zlib, bzip2 and iconv. It has no OpenSSL, x265,
AV1, VP8/VP9, Opus, LAME or FreeType code.

## x264

Copyright (C) 2003-2025 x264 project. Licensed under the GNU General Public
License version 2 or later. License text: `legal/x264/COPYING`. Author list:
`legal/x264/AUTHORS`, copied from the pinned source.
Project page: https://www.videolan.org/developers/x264.html

Configure line: `./configure --prefix=<prefix> --enable-static --disable-cli --enable-pic --disable-opencl`
(arm64, default 8 and 10 bit depth support).

## zimg

Copyright (C) Sam Hocevar and zimg contributors. Licensed under the WTFPL,
version 2. License text: `legal/zimg/COPYING`.
Project page: https://github.com/sekrit-twc/zimg

Configure line: `./autogen.sh && ./configure --prefix=<prefix> --enable-static --disable-shared --disable-testapp --disable-example --disable-unit-test`

## tsMuxeR

Copyright (C) the tsMuxer contributors. Licensed under the Apache License,
version 2.0. License text: `legal/tsMuxer/LICENSE`.
Project page: https://github.com/justdan96/tsMuxer

The app bundles the upstream 2.7.0 macOS arm64 release binary without
modification. It is re-signed with MindInMotion LLC's Developer ID so macOS
accepts it; signing does not change the program.

## libpng and FreeType (inside tsMuxeR)

The upstream tsMuxeR binary statically links libpng and FreeType, so both ship
inside `Contents/Resources/bin/tsMuxeR`. The binary reports libpng 1.6.47
(Copyright (c) 1995-2025 The PNG Reference Library Authors); its license text
and author list are in `legal/libpng/`. libpng is under the libpng License, a
permissive license compatible with the GPL.

FreeType is under the FreeType License (FTL). Portions of this software are
copyright (c) The FreeType Project (https://freetype.org). All rights reserved.
The upstream binary does not report its FreeType version. The FTL text is in
`legal/freetype/FTL.TXT`.
