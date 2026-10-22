#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
output_dir=$(mktemp -d /tmp/fcp-beautygirl-tracking-tests.XXXXXX)
trap 'rm -rf "$output_dir"' EXIT
# tracking_tests.m imports the implementation; do not link it a second time.
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter \
  -DCI_SILENCE_GL_DEPRECATION -mmacosx-version-min=13.0 \
  -framework Foundation -framework CoreImage -framework CoreGraphics \
  -framework CoreMedia -framework Metal -framework Vision -framework ImageIO \
  tests/tracking_tests.m -o "$output_dir/tracking-tests"
"$output_dir/tracking-tests"
