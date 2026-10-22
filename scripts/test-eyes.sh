#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
eye_test_output=$(mktemp -d /tmp/fcp-beautygirl-eye-tests.XXXXXX)
cleanup_eye_tests() {
  python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$eye_test_output"
}
trap cleanup_eye_tests EXIT
plugin_dir="$PWD/FCP-BeautyGirl/FCP-BeautyGirl/Plugin"
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter \
  -DCI_SILENCE_GL_DEPRECATION -mmacosx-version-min=13.0 -I "$plugin_dir" \
  -framework Foundation -framework CoreImage -framework CoreGraphics \
  -framework CoreMedia -framework Metal -framework Vision -framework ImageIO \
  "$plugin_dir/PGFaceProcessor.m" tests/eyes_tests.m -o "$eye_test_output/eye-tests"
"$eye_test_output/eye-tests" "$@"
