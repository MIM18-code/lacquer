#!/bin/bash
# End-to-end release gate: builds synthetic masters shaped like real ones,
# runs each through the real pipeline in headless mode, and checks the
# streams on the resulting discs. Run before every release:
#
#   swift build && Scripts/e2e_test.sh
#
# Uses the tools in packaging/vendor/runtime/bin (built by
# packaging/prepare_runtime.py); override with DISC_TOOLS_DIR.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="${BIN:-.build/debug/Lacquer}"
export DISC_TOOLS_DIR="${DISC_TOOLS_DIR:-$PWD/packaging/vendor/runtime/bin}"
FF="$DISC_TOOLS_DIR/ffmpeg"
FP="$DISC_TOOLS_DIR/ffprobe"
[ -x "$BIN" ] || { echo "build first: swift build" >&2; exit 1; }
[ -x "$FF" ] || { echo "no tools in $DISC_TOOLS_DIR; run packaging/prepare_runtime.py" >&2; exit 1; }

WORK="$(mktemp -d -t disc-e2e)"
MOUNTS=()
cleanup() {
    for m in ${MOUNTS[@]+"${MOUNTS[@]}"}; do hdiutil detach -quiet "$m" 2>/dev/null || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT
FX="$WORK/fx"; OUT="$WORK/out"; mkdir -p "$FX" "$OUT"
failures=0
check() {  # check <label> <actual> <expected>
    if [ "$2" = "$3" ]; then echo "  ok   $1 = $2"; else echo "  FAIL $1 = '$2', expected '$3'"; failures=$((failures + 1)); fi
}
probe() {  # probe <file> <stream selector> <entry>
    "$FP" -v error -select_streams "$2" -show_entries "stream=$3" -of default=nw=1:nk=1 "$1" | head -1
}
mount_iso() {
    local m
    m="$(hdiutil attach -nobrowse -readonly "$1" | tail -1 | awk -F'\t' '{print $NF}')"
    MOUNTS+=("$m")
    echo "$m"
}

echo "== making fixtures"
q=(-hide_banner -loglevel error -y)
# Resolve-style 5.1 master: six discrete mono tracks, L R C LFE Ls Rs.
"$FF" "${q[@]}" -f lavfi -i testsrc2=s=1920x1080:r=24000/1001:d=12 \
    $(for f in 220 330 440 60 550 880; do printf -- "-f lavfi -i sine=f=$f:d=12:r=48000 "; done) \
    -map 0:v $(for i in 1 2 3 4 5 6; do printf -- "-map $i:a "; done) \
    -c:v prores_ks -profile:v 1 -c:a pcm_s24le "$FX/mono6.mov"
# Phone-style 29.97p with stereo AAC.
"$FF" "${q[@]}" -f lavfi -i testsrc2=s=1920x1080:r=30000/1001:d=12 -f lavfi -i sine=f=440:d=12 \
    -ac 2 -c:v libx264 -preset ultrafast -c:a aac -shortest "$FX/phone.mp4"
# HLG HDR, 25p, no audio. x265 isn't in the minimal build, so tag 10-bit ProRes as HLG.
# prores_ks only writes color tags that arrive on the frames, hence setparams.
"$FF" "${q[@]}" -f lavfi -i testsrc2=s=1920x1080:r=25:d=8 \
    -vf "format=yuv422p10le,setparams=color_trc=arib-std-b67:color_primaries=bt2020:colorspace=bt2020nc" \
    -c:v prores_ks -profile:v 2 "$FX/hlg.mov"
# 720p with a double quote in the name and no audio.
"$FF" "${q[@]}" -f lavfi -i testsrc2=s=1280x720:r=24:d=8 -c:v libx264 -preset ultrafast "$FX/quote \"name\".mov"

run() { "$BIN" --headless --one-pass --output-dir "$OUT" "$@" > "$WORK/run.txt" 2>&1 || { cat "$WORK/run.txt"; failures=$((failures + 1)); return 1; }; }

echo "== discrete mono → 5.1 ISO"
if run --mode iso --input "$FX/mono6.mov"; then
    iso="$OUT/mono6_BluRay.iso"
    check "UDF 2.50 anchor" "$(LC_ALL=C grep -a -c NSR03 "$iso" | awk '{print ($1 > 0) ? "NSR03" : "none"}')" "NSR03"
    m="$(mount_iso "$iso")"
    s="$m/BDMV/STREAM/00000.m2ts"
    check "volume label" "$(diskutil info "$m" | awk -F': *' '/Volume Name/ {print $2}')" "MONO6"
    check "audio channels" "$(probe "$s" a:0 channels)" "6"
    check "video rate" "$(probe "$s" v:0 r_frame_rate)" "24000/1001"
    # Zero-crossing rate tracks frequency: C carries 440 Hz, LFE 60 Hz.
    zc="$("$FF" -hide_banner -i "$s" -map 0:a -af astats=measure_overall=none:measure_perchannel=Zero_crossings_rate -f null - 2>&1 \
        | awk '/Zero crossings rate/ {printf "%d ", $NF*24000}')"
    read -r fl fr fc lfe sl sr <<< "$zc"
    check "C channel is the 440 Hz track" "$([ "$fc" -gt 400 ] && [ "$fc" -lt 480 ] && echo yes || echo "no ($zc)")" "yes"
    check "LFE channel is the 60 Hz track" "$([ "$lfe" -gt 40 ] && [ "$lfe" -lt 90 ] && echo yes || echo "no ($zc)")" "yes"
    check "chapters in playlist" "$([ -s "$m/BDMV/PLAYLIST/00000.mpls" ] && echo yes)" "yes"
fi

echo "== 29.97p → 1080i29.97 BDMV"
if run --mode bdmv --input "$FX/phone.mp4"; then
    s="$OUT/phone_BluRay/BDMV/STREAM/00000.m2ts"
    check "field order" "$(probe "$s" v:0 field_order)" "tt"
    check "video rate" "$(probe "$s" v:0 r_frame_rate)" "30000/1001"
    check "audio channels" "$(probe "$s" a:0 channels)" "2"
    check "audio bitrate capped" "$(probe "$s" a:0 bit_rate)" "448000"
fi

echo "== HLG → tonemapped 1080i25 M2TS"
if run --mode m2ts --input "$FX/hlg.mov"; then
    s="$OUT/hlg_BluRay.m2ts"
    check "tonemap noted" "$(grep -q 'tonemapped to SDR' "$WORK/run.txt" && echo yes)" "yes"
    check "transfer" "$(probe "$s" v:0 color_transfer)" "bt709"
    check "silent audio track" "$(probe "$s" a:0 codec_name)" "ac3"
fi

echo "== quote in file name, no audio → ISO"
if run --mode iso --input "$FX/quote \"name\".mov"; then
    iso="$OUT/quote 'name'_BluRay.iso"
    check "output renamed" "$([ -f "$iso" ] && echo yes)" "yes"
    m="$(mount_iso "$iso")"
    check "upscaled to 1080" "$(probe "$m/BDMV/STREAM/00000.m2ts" v:0 height)" "1080"
    check "audio channels" "$(probe "$m/BDMV/STREAM/00000.m2ts" a:0 channels)" "2"
fi

echo "== review regressions: anamorphic, late audio, cover art, short clip"
# Anamorphic NTSC widescreen: a 120×120 stored square must come out 32:27 wide.
ff_box="drawbox=x=300:y=180:w=120:h=120:c=white:t=fill"
"$FF" "${q[@]}" -f lavfi -i "color=c=black:s=720x480:r=24000/1001:d=3,$ff_box" -vf setsar=32/27 -c:v libx264 -preset ultrafast "$FX/anamorphic.mov"
# Audio that starts one second after the picture.
"$FF" "${q[@]}" -f lavfi -i "testsrc2=s=1280x720:r=24:d=5" -itsoffset 1 -f lavfi -i "sine=f=1000:d=4" -c:v libx264 -preset ultrafast -c:a pcm_s16le "$FX/late.mov"
# Cover art stored before the film's video stream.
"$FF" "${q[@]}" -f lavfi -i color=c=blue:s=64x64 -frames:v 1 "$FX/cover.png"
"$FF" "${q[@]}" -f lavfi -i "testsrc2=s=1920x1080:r=24:d=3" -i "$FX/cover.png" -map 1:v -map 0:v -c:v:0 png -c:v:1 libx264 -preset ultrafast -disposition:v:0 attached_pic "$FX/covered.mp4"
# Three seconds of flat grey: tiny output that must still pass the size check.
"$FF" "${q[@]}" -f lavfi -i "color=c=gray:s=320x240:r=24:d=3" -c:v libx264 "$FX/short.mov"
if run --mode m2ts --standard 1080p23.976 --input "$FX/anamorphic.mov"; then
    "$FF" "${q[@]}" -ss 1 -i "$OUT/anamorphic_BluRay.m2ts" -frames:v 1 -vf "crop=1920:1080,format=gray" -f rawvideo "$WORK/frame.gray"
    ratio="$(python3 -c "
import sys
w, h, d = 1920, 1080, open(sys.argv[1], 'rb').read()
xs = [i % w for i, b in enumerate(d) if b > 128]; ys = [i // w for i, b in enumerate(d) if b > 128]
print('%.2f' % ((max(xs) - min(xs) + 1) / (max(ys) - min(ys) + 1)))" "$WORK/frame.gray")"
    check "anamorphic square shape (32:27 ≈ 1.18)" "$ratio" "1.18"
fi
if run --mode m2ts --input "$FX/late.mov"; then
    end="$("$FF" -hide_banner -i "$OUT/late_BluRay.m2ts" -map 0:a -af silencedetect=n=-50dB:d=0.3 -f null - 2>&1 | awk '/silence_end/ {print int($5 * 10 + 0.5) / 10; exit}')"
    check "late audio keeps its 1 s offset" "$end" "1"
fi
if run --mode m2ts --input "$FX/covered.mp4"; then
    check "film used, not cover art" "$(probe "$OUT/covered_BluRay.m2ts" v:0 width)" "1920"
fi
for m in m2ts bdmv iso; do run --mode "$m" --input "$FX/short.mov" && check "3 s clip as $m" ok ok; done

echo "== too long for the disc is refused before encoding"
# 60 hours at 1 fps: past what BD-25 holds even at the 1 Mbps floor.
"$FF" "${q[@]}" -f lavfi -i color=c=black:s=64x64:r=1:d=216000 -c:v libx264 -preset ultrafast "$FX/marathon.mkv"
check "BD-25 refuses" "$("$BIN" --headless --plan-only --input "$FX/marathon.mkv" >/dev/null 2>&1; echo $?)" "1"
check "M2TS allows" "$("$BIN" --headless --plan-only --mode m2ts --input "$FX/marathon.mkv" >/dev/null 2>&1; echo $?)" "0"

echo
if [ "$failures" -eq 0 ]; then echo "PASS"; else echo "FAILED: $failures check(s)"; exit 1; fi
