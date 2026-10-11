#!/bin/bash
# Thin wrapper kept for muscle memory. The release pipeline lives in
# packaging/make_dmg.sh; names and versions in packaging/app.env.
exec "$(cd "$(dirname "$0")/.." && pwd)/packaging/make_dmg.sh" "$@"
