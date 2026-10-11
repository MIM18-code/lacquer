#!/bin/bash
# Exercise a bundled tool set end to end: decode/encode paths the app uses,
# the HDR tone-map chain, and a Blu-ray mux with tsMuxeR.
# Usage: smoke_test.sh <dir containing ffmpeg, ffprobe, tsMuxeR>
set -euo pipefail
BIN="${1:?usage: smoke_test.sh <bin dir>}"
FFMPEG="$BIN/ffmpeg"; FFPROBE="$BIN/ffprobe"; TSMUXER="$BIN/tsMuxeR"
T="$(mktemp -d -t bdsmoke)"
trap 'rm -rf "$T"' EXIT
ff() { "$FFMPEG" -hide_banner -loglevel error -nostdin -y "$@"; }
probe() { "$FFPROBE" -v error -show_entries "$1" -of default=nw=1:nk=1 "$2"; }
expect() { [ "$1" = "$2" ] || { echo "FAIL: $3 (got '$1', want '$2')" >&2; exit 1; }; echo "ok: $3"; }

# 1. Blu-ray style encode: testsrc2 + 5.1 sine -> raw h264 + ac3
ff -f lavfi -i "testsrc2=size=1920x1080:rate=24000/1001:duration=2" \
   -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" \
   -vf "scale=1920:1080,setsar=1,format=yuv420p" \
   -c:v libx264 -preset veryfast -profile:v high -level:v 4.1 -b:v 8M -maxrate 15M -bufsize 15M \
   -an -f h264 "$T/v.h264"
ff -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" \
   -af "pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0" -c:a ac3 -b:a 448k -ar 48000 -f ac3 "$T/a.ac3"
expect "$(probe stream=codec_name "$T/v.h264")" h264 "libx264 raw .h264"
expect "$(probe stream=codec_name "$T/a.ac3")" ac3 "ac3 encode"
expect "$(probe stream=channels "$T/a.ac3")" 6 "ac3 is 5.1"

# 2. Interlaced path: bwdif, interlace, setfield
ff -f lavfi -i "testsrc2=size=1920x1080:rate=30000/1001:duration=1" \
   -vf "bwdif=mode=0:parity=auto:deint=all,scale=1280:720,setsar=1,format=yuv420p" -c:v libx264 -f null -
ff -f lavfi -i "testsrc2=size=1920x1080:rate=30000/1001:duration=1" \
   -vf "interlace=scan=tff:lowpass=0,setfield=tff,format=yuv420p" -c:v libx264 -flags +ildct+ilme -x264opts tff=1 -f null -
echo "ok: bwdif / interlace / setfield"

# 3. HDR -> SDR tone map via zimg
ff -f lavfi -i "testsrc2=size=1280x720:rate=24:duration=1" \
   -vf "format=yuv420p10le,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc,zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p" \
   -c:v libx264 -f null -
echo "ok: zscale + tonemap chain"

# 4. Masters: ProRes 4444 with alpha + PCM in MOV, DNxHR, HEVC 10-bit in MP4 (decode paths)
ff -f lavfi -i "testsrc2=size=640x360:rate=24:duration=1,format=yuva444p10le" \
   -f lavfi -i "sine=sample_rate=48000:duration=1" \
   -c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le -c:a pcm_s24le "$T/prores.mov"
expect "$(probe stream=codec_name "$T/prores.mov" | head -1)" prores "ProRes 4444 written"
ff -i "$T/prores.mov" -f null -
echo "ok: ProRes 4444 + alpha + PCM decode"
ff -f lavfi -i "testsrc2=size=1920x1080:rate=24:duration=1,format=yuv422p" -c:v dnxhd -profile:v dnxhr_hq "$T/dnx.mxf"
ff -i "$T/dnx.mxf" -f null -
echo "ok: DNxHR in MXF decode"
# HEVC 10-bit: no encoder in this build, so decode is checked through the decoder list in
# prepare_runtime.py; videotoolbox hwaccel presence is asserted there too.

# 5. tsMuxeR: mux to a Blu-ray transport stream
cat > "$T/mux.meta" <<META
MUXOPT --no-pcr-on-video-pid --new-audio-pes --vbr --vbv-len=500
V_MPEG4/ISO/AVC, "$T/v.h264", fps=23.976, insertSEI, contSPS
A_AC3, "$T/a.ac3"
META
"$TSMUXER" "$T/mux.meta" "$T/out.m2ts" >/dev/null
[ -s "$T/out.m2ts" ] || { echo "FAIL: tsMuxeR produced no m2ts" >&2; exit 1; }
echo "ok: tsMuxeR m2ts ($(stat -f %z "$T/out.m2ts") bytes)"
echo "smoke test passed"
