#!/bin/zsh
# Diagnostic statistics for authored inputs; a zero exit is not a stability pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/tracking-diagnostics"
mkdir -p "$WORK"
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter \
  -DCI_SILENCE_GL_DEPRECATION -mmacosx-version-min=13.0 \
  -I "$ROOT/FCP-BeautyGirl/FCP-BeautyGirl/Plugin" \
  -framework Foundation -framework CoreImage -framework CoreGraphics \
  -framework CoreMedia -framework Metal -framework Vision -framework ImageIO \
  "$ROOT/FCP-BeautyGirl/FCP-BeautyGirl/Plugin/PGFaceProcessor.m" \
  "$ROOT/scripts/diagnose-tracking.m" -o "$WORK/tracking-probe"
"$WORK/tracking-probe"
