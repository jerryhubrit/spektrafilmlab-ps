# Third-party attribution and changes

SpektraFilmLab PS is an **unofficial Photoshop integration**, maintained by [jerryhubrit](https://github.com/jerryhubrit). It is not an official Adobe, SpektraLab, Kodak, Fujifilm or ILFORD product.

## SpektraLab

- Project: https://github.com/JamesQiu2005/SpektraLab
- Authors: JamesQiu2005 and contributors.
- Source revision included here: `02d82b56cf65f0f8e802a708612edc4e9a4790af`.
- Software license: GNU GPL v3; original text is preserved in `vendor/SpektraLab/LICENSE.txt` and the root `LICENSE`.
- The native C++/Metal engine, its C ABI and its film edge/date-imprint implementation are reused. Tracked engine source, build script, dependencies and resources are included under `vendor/SpektraLab/engine/`.
- RAW decoding conventions are adapted from `ImageDecoder.swift`; film/date format geometry, edge lettering and typed shooting-data extraction are adapted from `FilmEdge.swift` and `Session+FilmEdge.swift` at that revision. Our Swift/UXP implementation of those adaptations is included in `helper/` and `plugin/`.

## spektrafilm

- Original film-emulation project and profile/LUT author: **Andrea Volpato and contributors**.
- Canonical source: https://github.com/andreavolpato/spektrafilm
- Profiles, LUTs and their direct encodings are licensed **Creative Commons Attribution-ShareAlike 4.0**, separately from the software. The original unmodified notice and full license are preserved in `licenses/SPEKTRAFILM_LICENSE.txt`.
- Profile measurements and baked constants are distributed unchanged from the pinned SpektraLab snapshot. We do not claim authorship of the film science, measured profiles or spectral model.
- The Metal library is rebuilt from the included upstream shader source for the macOS 15 deployment target, with safe/precise math retained. See `docs/BUILD.md` and `upstream.json`.

## What this project adds

Photoshop UXP workbench; local Swift HTTP bridge; direct RAW opening; preview scheduling and decoded-frame reuse; full-resolution RGB16 ProPhoto handoff; film-edge/date controls; result-canvas sizing; per-install access tokens; and a self-contained Mac installer. These integration sources are distributed under GNU GPL v3.

The engine algorithms are not rewritten. Installer/build configuration and integration code are separate from upstream source. Local experiments on the standalone SpektraLab application are not represented as part of this release.

## Other dependencies

Original third-party notices are retained under `vendor/SpektraLab/engine/third_party/`, including `metal-cpp`, `stb`, and `volk`. The release also carries these notices in its `licenses/third_party/` directory. Apple frameworks and Adobe Photoshop/Creative Cloud are external platform dependencies and are not redistributed.

Brand names describe the original film profiles. This project does not assert ownership of those trademarks.
