# Build from source

The repository contains the corresponding integration and native engine source, shader source, build scripts, third-party headers and the baked profile/LUT resources used by the binary release. No private source checkout is required.

## Requirements

- Apple Silicon Mac, Xcode command-line tools / SDK with the Metal compiler installed.
- Python 3 for release ZIP assembly and tests; Node.js for JavaScript unit tests. End users do not need either runtime.
- The released build was made with Xcode 26.6 tooling and the Metal toolchain installed on the developer machine, targeting **macOS 15.0**.

```sh
git clone https://github.com/jerryhubrit/spektrafilmlab-ps.git
cd spektrafilmlab-ps
# Select your Xcode installation if it is not the active developer directory.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash scripts/build-macos.sh
python3 scripts/package-release.py
node --test tests/panel-state.test.cjs tests/film-effects.test.cjs
python3 tests/release-package.test.py
```

RAW 边界额外验证：`bash scripts/test-raw-pipeline.sh --full /absolute/path/sample.NEF`。无相机文件时必须显式使用 `--synthetic-only`，报告会标明相机覆盖未运行。安装包端到端 RAW 验证可将路径追加到 `python3 tests/release-package.test.py /absolute/path/sample.NEF`；这会在独立 49322 端口调用完整显影及输出格式检查。详见 [RAW-PIPELINE.md](RAW-PIPELINE.md)。

If Xcode reports the Metal compiler is missing, install the Metal Toolchain component through Xcode. Do not remove safe/precise math flags from the engine build to work around a toolchain problem.

`MACOSX_DEPLOYMENT_TARGET=15.0` applies to the C++ engine. Swift binaries explicitly target `arm64-apple-macos15.0`. Upstream's Metal build targets macOS 15 and checks that target. Each executable/dylib is ad-hoc signed after compilation, not Developer ID signed or notarized. Exact Mach-O bytes can vary by toolchain; source revision and release artifact SHA256 values are recorded.

## Local validation without changing an installed plugin

`FilmLabSetup prepare PACKAGE TEST_DEST 49322` creates a private test installation with a separate token and port. `start-at TEST_DEST` / `stop-at TEST_DEST` manage only that test helper. See the release-package test for this isolation.

Native smoke tests accept `FILMLAB_CONFIG=/absolute/path/config.json`; absent that variable they look for `plugin/config.json`. The test config sets the local port. These tests replace the helper's source cache, so never point them at a helper currently used for editing.

```sh
FILMLAB_CONFIG=/tmp/your-test-install/config.json python3 tests/native_smoke.py
FILMLAB_CONFIG=/tmp/your-test-install/config.json python3 tests/edge_smoke.py
# Optional: supplied local RAW, never uploaded or copied into this repository.
FILMLAB_CONFIG=/tmp/your-test-install/config.json python3 tests/raw_smoke.py /path/to/photo.ARW --full
```

## Upstream provenance

`upstream.json` pins SpektraLab commit `02d82b56cf65f0f8e802a708612edc4e9a4790af`. The engine source is unmodified; this project's wrapper sets the deployment target. The packaged Metal library is rebuilt from those shaders, and profiles/constants are preserved. Original upstream licenses travel with the source and binaries. See `NOTICE.md` for the original spektrafilm attribution and resource license.
