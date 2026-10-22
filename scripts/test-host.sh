#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
output_dir=$(mktemp -d /tmp/fcp-beautygirl-host-tests.XXXXXX)
trap 'rm -rf "$output_dir"' EXIT
plugin_dir="$PWD/FCP-BeautyGirl/FCP-BeautyGirl/Plugin"
sdk_frameworks=/Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks
runtime_frameworks=/Library/Developer/Frameworks
compiler_extra=()
if [[ "${FCP_BEAUTYGIRL_HOST_ASAN:-0}" == 1 ]]; then
  compiler_extra=(-fsanitize=address -g)
fi
xcrun clang "${compiler_extra[@]}" -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter \
  -DCI_SILENCE_GL_DEPRECATION -mmacosx-version-min=13.0 \
  -I "$plugin_dir" -F "$sdk_frameworks" -F "$runtime_frameworks" \
  -Wl,-rpath,"$runtime_frameworks" \
  "$plugin_dir/PGBeautyRenderer.m" "$plugin_dir/PGFaceProcessor.m" \
  "$plugin_dir/PGInspectorState.m" "$plugin_dir/PGInspectorView.m" \
  "$plugin_dir/FCPBeautyGirlPlugIn.m" tests/host_adapter_tests.m \
  -framework Foundation -framework AppKit -framework CoreImage -framework CoreGraphics \
  -framework CoreMedia -framework CoreVideo -framework IOSurface -framework Metal \
  -framework Vision -framework ImageIO -framework FxPlug -framework PluginManager \
  -o "$output_dir/host-tests"
"$output_dir/host-tests" "$PWD/tests/fixtures/astronaut.png" "$@"
