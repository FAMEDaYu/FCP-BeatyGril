#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
output_dir=$(mktemp -d /tmp/fcp-beautygirl-inspector-tests.XXXXXX)
trap 'rm -rf "$output_dir"' EXIT
plugin_dir="$PWD/FCP-BeautyGirl/FCP-BeautyGirl/Plugin"
compiler_extra=()
if [[ "${FCP_BEAUTYGIRL_INSPECTOR_ASAN:-0}" == 1 ]]; then
  compiler_extra=(-fsanitize=address -g)
fi
python3 scripts/inspector-template.py audit 'Templates/大鱼人像美化/大鱼人像美化.moef' \
  --inner-output "$output_dir/template-inner.bplist" --outer-output "$output_dir/template-outer.bplist" > /dev/null
xcrun clang "${compiler_extra[@]}" -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter \
  -DCI_SILENCE_GL_DEPRECATION -mmacosx-version-min=13.0 -I "$plugin_dir" \
  -F /Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks -F /Library/Developer/Frameworks \
  -Wl,-rpath,/Library/Developer/Frameworks \
  "$plugin_dir/PGBeautyRenderer.m" "$plugin_dir/PGFaceProcessor.m" \
  "$plugin_dir/PGInspectorState.m" "$plugin_dir/PGInspectorView.m" \
  "$plugin_dir/FCPBeautyGirlPlugIn.m" tests/inspector_tests.m \
  -framework Foundation -framework AppKit -framework CoreImage -framework CoreGraphics \
  -framework CoreMedia -framework CoreVideo -framework IOSurface -framework Metal \
  -framework Vision -framework ImageIO -framework FxPlug -framework PluginManager \
  -o "$output_dir/inspector-tests"
"$output_dir/inspector-tests" "$output_dir/template-inner.bplist" "$output_dir/template-outer.bplist"
