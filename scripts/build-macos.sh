#!/bin/bash
set -euo pipefail
filmlab_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
filmlab_engine="$filmlab_root/vendor/SpektraLab/engine"
export MACOSX_DEPLOYMENT_TARGET=15.0
mkdir -p "$filmlab_root/build/bin" "$filmlab_root/build/module-cache"
if [[ "${1:-}" != "--reuse-engine" || ! -f "$filmlab_engine/build/libspektrafilm_engine.dylib" ]]; then
  bash "$filmlab_engine/build.sh" dylib
fi
cp "$filmlab_engine/build/libspektrafilm_engine.dylib" "$filmlab_root/build/bin/"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 \
  -module-cache-path "$filmlab_root/build/module-cache" \
  -import-objc-header "$filmlab_engine/include/spektrafilm/spk_engine.h" \
  -L "$filmlab_root/build/bin" -lspektrafilm_engine -Xlinker -rpath -Xlinker @executable_path \
  -framework Network -framework CoreGraphics -framework ImageIO -framework CoreImage -framework Metal \
  "$filmlab_root/helper/main.swift" "$filmlab_root/helper/RAWSource.swift" -o "$filmlab_root/build/bin/FilmLabHelper"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 \
  -module-cache-path "$filmlab_root/build/module-cache" \
  "$filmlab_root/installer/main.swift" -o "$filmlab_root/build/bin/FilmLabSetup"
for filmlab_binary in "$filmlab_root/build/bin/"*; do /usr/bin/codesign --force --sign - "$filmlab_binary"; done
printf 'Built macOS 15+ arm64 helper and installer.\n'
