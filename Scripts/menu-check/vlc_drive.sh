#!/bin/bash
# Builds and runs vlc_drive against /Applications/VLC.app (VLC 3).
set -euo pipefail
cd "$(dirname "$0")"
V=/Applications/VLC.app/Contents/MacOS
if [ ! -x vlc_drive ] || [ vlc_drive.c -nt vlc_drive ]; then
    cc -std=c11 -Wall -o vlc_drive vlc_drive.c -I"$V/include" -L"$V/lib" -lvlc -Wl,-rpath,"$V/lib"
fi
VLC_PLUGIN_PATH="$V/plugins" ./vlc_drive "$1" "$2" 2>&1 | grep -v "Referenced from\|Reason: tried"
