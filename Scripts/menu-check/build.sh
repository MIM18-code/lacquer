#!/bin/bash
# Builds menu_check against Homebrew's libbluray (brew install libbluray).
set -euo pipefail
cd "$(dirname "$0")"
PKG_CONFIG_PATH="$(brew --prefix libbluray)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PKG_CONFIG_PATH
cc -std=c11 -Wall -Wextra -O1 -o menu_check menu_check.c $(pkg-config --cflags --libs libbluray)
echo "built $(pwd)/menu_check"
