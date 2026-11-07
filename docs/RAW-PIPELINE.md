# RAW 解码、线性化与 Photoshop 交接

## 这次检查解决什么

“只移植胶片引擎，不一定正确处理 RAW”是合理的提醒。RAW 解码、色彩变换和图像交接必须一起验证。v0.3.2 没有改写胶片算法，也没有发现并声称修复一个已经证实的重复伽马问题；本次补充了原生像素一致性测试，以及写入 PS 前的像素格式校验。

## TIFF 是旧的传输方式，不是 RAW 解码的必要步骤

本项目固定使用的 SpektraLab 提交为 `02d82b56cf65f0f8e802a708612edc4e9a4790af`。该版本的 [ImageDecoder.swift](https://github.com/JamesQiu2005/SpektraLab/blob/02d82b56cf65f0f8e802a708612edc4e9a4790af/modern_UI/Spektrafilm/Spektrafilm/Import/ImageDecoder.swift) 已明确采用 `engineFrame`：Core Image 将图像直接渲染成内存中的 Float32 RGBA、线性 ProPhoto，再送给引擎。文件中的注释说明它取代了早期半浮点 TIFF 的写入／读回。

我们的辅助程序也使用 `CIRAWFilter`。它与上游的内存传输方式一致，没有因为省略 TIFF 就省略 RAW 解码或色彩管理，也没有让 Photoshop/Adobe Camera Raw 代替 Apple 解码。两种 RAW 解码器的结果不保证一致。

## 各边界的明确约定

| 阶段 | 数据与责任 |
|---|---|
| RAW → Core Image | Apple `CIRAWFilter` 去马赛克、相机处理与白平衡；是否支持某相机由本机 macOS 决定 |
| 胶片用解码 | 关闭 `boostAmount`、`boostShadowAmount`、gamut mapping、local tone mapping 和 EDR；其他相机默认值沿用上游，不额外把 baseline exposure 归零 |
| 对照用解码 | 独立滤镜，保留 Apple 默认呈现；与胶片用解码共享白平衡和镜头几何，不作为胶片引擎输入 |
| Core Image 内部 | 与上游相同的 extended-linear Display P3 工作空间、RGBAh 内部工作格式；因此不宣称每个内部步骤都是 Float32 |
| Core Image → 引擎 | `render(toBitmap:)` 输出 Float32 RGBA、D50 线性 ProPhoto、顶行优先；不额外调用 `matchedToWorkingSpace`，不写显示用 TIFF，不量化为 UInt16 |
| RAW 引擎参数 | `input_color_space = ProPhoto RGB`，`input_cctf_decoding = false`，避免再次逆伽马 |
| PS 合成图入口 | PS 转成已编码 ProPhoto RGB，作为已显影图像读取；`input_cctf_decoding = true`。这不能恢复原始 RAW 高光或相机白平衡 |
| 引擎 → PS | 全范围、紧密排列、小端 UInt16 RGBA；ProPhoto 输出传递函数已应用；PS 使用相同 profile 并以 `fullRange: true` 写入 16 位文档 |

Apple 说明 Core Image 会在输入、工作与目标色彩空间之间执行颜色匹配，见 [workingColorSpace](https://developer.apple.com/documentation/coreimage/cicontextoption/workingcolorspace)。因此目标色彩空间和是否再做传递函数变换，都是数据契约的一部分，不只是文件标签。

“Float32 线性输入”不代表最终 PS 文件仍是场景线性 HDR。胶片与相纸显影之后，输出为已编码的 16 位图像，继续供 PS 精修。

## v0.3.2 新增的交接保护

完整尺寸 `/render` 与 `/raw/render` 响应必须携带：

```text
X-Pixel-Format: rgba16le
X-Color-Space: ProPhoto RGB
X-Transfer-Function: romm-rgb
X-Row-Order: top-down
```

`romm-rgb` 指引擎使用的 ProPhoto/ROMM 分段传递函数，包含暗部线性段，并非把全范围简单乘上一个 gamma。它只描述完整输出；sRGB PNG 预览不使用这组标签。

面板在创建文档或写入图层之前核对四个字段。缺少字段、线性数据误标、非 ProPhoto 数据、不同位深或反向行排列都会被拒绝，提示使用配套的新版引擎。升级必须同时更新面板和辅助程序，并重启旧引擎。

这些字段防止组件之间的约定失配，不能单独证明像素正确。下面的测试直接检查像素和实际 Metal 渲染。

## 如何复现验证

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash scripts/build-macos.sh --reuse-engine
# 必须显式指定本机 RAW；路径仅传给本机进程，不写入报告。
bash scripts/test-raw-pipeline.sh --full /absolute/path/sample.NEF /absolute/path/sample.CR2
# 只有合成测试时必须明确指定，结果会标注未运行相机 RAW 测试。
bash scripts/test-raw-pipeline.sh --synthetic-only
node --test tests/panel-state.test.cjs tests/film-effects.test.cjs
```

原生测试使用固定上游版本的滤镜设置、独立定义的 ProPhoto 基色与白点、Core Image context 作为参考。覆盖：

- 大于 1 的线性高光、18% 灰、行方向、预览缩小。
- 同一场景的线性输入与 ProPhoto 编码输入，经真实 Metal 显影后结果一致；故意多做一次逆伽马作为负对照，必须产生显著差异。
- 本机 RAW 的默认／自定义白平衡／恢复拍摄时设置／镜头开关，以及预览和可选全尺寸解码一致性。
- RAW 与原图对照的几何尺寸一致，错误格式响应不能创建 PS 文档。

本次检查使用 [rawpy 公开测试目录](https://github.com/letmaik/rawpy/tree/main/test) 的 NEF 与 CR2。照片仅下载到被忽略的 `build/raw-fixtures/`，不包含在仓库、安装包或源码包中；不改变原文件的许可，也不用于宣传图。文件哈希与验证结果见 [RAW-VALIDATION.md](RAW-VALIDATION.md)。

## 还没有证明的范围

两张相机测试文件不能覆盖所有品牌、压缩 RAW、DNG/ProRAW 或每个 macOS 解码器版本。原来客户 ARW 的本机路径已失效，本轮尚未重新测试该文件，也未重新执行 Photoshop 实机 UI 验收。JS 回归使用模拟宿主 API，不能代替 Adobe 宿主端验收。
