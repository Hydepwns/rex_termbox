#!/usr/bin/env bash
set -euo pipefail

# Build the NIF
mix deps.get
mix compile

# Find the built NIF
NIF_PATH=$(find deps -name '*.so' -o -name '*.dylib' -o -name '*.dll' | head -n1)
if [ -z "$NIF_PATH" ]; then
  echo "NIF binary not found!" >&2
  exit 1
fi

# Detect platform
UNAME=$(uname -s)
ARCH=$(uname -m)
EXT="${NIF_PATH##*.}"

case "$UNAME" in
  Linux)
    TARGET="x86_64-unknown-linux-gnu" # Adjust for ARM if needed
    ;;
  Darwin)
    if [ "$ARCH" = "arm64" ]; then
      TARGET="aarch64-apple-darwin"
    else
      TARGET="x86_64-apple-darwin"
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    TARGET="x86_64-pc-windows-msvc"
    ;;
  *)
    echo "Unsupported platform: $UNAME/$ARCH" >&2
    exit 1
    ;;
esac

OUT="rrex_termbox_nif-${TARGET}.${EXT}"
cp "$NIF_PATH" "$OUT"
echo "Precompiled NIF written to: $OUT" 