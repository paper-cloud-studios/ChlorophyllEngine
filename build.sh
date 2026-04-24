# ============================================================
#  CHLOROPHYLL SDK  —  build.sh
#
#  Builds the SDK workspace.
#  Requires: Odin compiler (https://odin-lang.org)
#            SDL2 dev libraries
# ============================================================

#!/usr/bin/env bash
set -e

BINARY="chlorophyll"
SRC="."

# Debug build (default)
odin build $SRC \
    -out:$BINARY \
    -debug \
    -collection:vendor=vendor \
    -extra-linker-flags:"-lSDL2 -lGL" \
    "$@"

echo "✓ Built: $BINARY"
