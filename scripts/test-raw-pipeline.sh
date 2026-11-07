#!/bin/bash
set -euo pipefail
if [[ $# -eq 0 ]]; then
  printf 'Supply local RAW paths (optionally --full), or explicitly use --synthetic-only.\n' >&2
  exit 2
fi
filmlab_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
filmlab_engine="$filmlab_root/vendor/SpektraLab/engine"
mkdir -p "$filmlab_root/build/bin" "$filmlab_root/build/module-cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 -D RAW_PIPELINE_TEST \
  -module-cache-path "$filmlab_root/build/module-cache" \
  -import-objc-header "$filmlab_engine/include/spektrafilm/spk_engine.h" \
  -L "$filmlab_root/build/bin" -lspektrafilm_engine -Xlinker -rpath -Xlinker @executable_path \
  -framework Network -framework CoreGraphics -framework ImageIO -framework CoreImage -framework Metal \
  "$filmlab_root/helper/main.swift" "$filmlab_root/helper/RAWSource.swift" \
  "$filmlab_root/tests/raw_pipeline.swift" -o "$filmlab_root/build/raw-pipeline-tests"
# The test executable is deliberately outside build/bin: it must not ship.
DYLD_LIBRARY_PATH="$filmlab_root/build/bin" "$filmlab_root/build/raw-pipeline-tests" "$filmlab_engine/resources" "$@"
