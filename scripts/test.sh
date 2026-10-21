#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
output_dir=$(mktemp -d /tmp/paintfcp-tests.XXXXXX)
trap 'rm -rf "$output_dir"' EXIT
plugin_dir="$PWD/beatygril/beatygril/Plugin"
common=(-fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter -DCI_SILENCE_GL_DEPRECATION -mmacosx-version-min=13.0 -I "$plugin_dir" -framework Foundation -framework CoreImage -framework CoreGraphics -framework CoreMedia -framework Metal -framework Vision -framework ImageIO)
xcrun clang "${common[@]}" "$plugin_dir/PGBeautyRenderer.m" tests/beauty_render_tests.m -o "$output_dir/beauty-tests"
"$output_dir/beauty-tests"
xcrun clang "${common[@]}" "$plugin_dir/PGFaceProcessor.m" tests/face_tests.m -o "$output_dir/face-tests"
"$output_dir/face-tests" "$PWD/tests/fixtures/astronaut.png"
