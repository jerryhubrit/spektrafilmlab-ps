# 安装与使用

## 安装前

需要 Apple 芯片 Mac、macOS 15 或更新、Photoshop 25 或更新，以及 Adobe Creative Cloud 桌面程序。当前实测环境为 macOS 26.6.2 / Photoshop 27.11.0。此包不支持 Windows 或 Intel Mac。

从本项目 [v0.3.2 Release](https://github.com/jerryhubrit/spektrafilmlab-ps/releases/tag/v0.3.2) 下载完整 ZIP，解压到一个保留的位置。不要只下载源代码 ZIP，也不要只取出一个可执行文件。

## 第一次安装

1. 双击 `安装.command`。首次启动未公证软件，macOS 可能会阻止运行。
2. 确认文件来自本项目 Release 后，可按 macOS 提示前往“系统设置 → 隐私与安全性”，对这次被拦截的程序选择“仍要打开”。也可先按住 Control 点文件查看系统是否提供“打开”。安装器不会绕过这些确认。
3. 等待 Adobe 插件安装器完成。引擎随后在后台启动，不需要保持终端窗口打开。
4. 打开 PS → 增效工具 → SpektraFilmLab PS → SpektraFilmLab RAW 显影工作台。
5. 打开 RAW，调好后点“显影并送入 Photoshop”。

Apple 官方说明：[在 Mac 上安全地打开 App](https://support.apple.com/102445)。本项目没有 Developer ID 公证，所以不能保证第一次下载完全没有系统确认。

## 平时使用

- 重启电脑后双击 `启动引擎.command`，再开 PS 面板。本版不添加开机登录项。
- 用完双击 `停止引擎.command`。
- 安装完成后，程序与资源保留在 `~/Library/Application Support/SpektraFilmLab PS/`。
- 把完整 Release ZIP 发给别人；**不要转发安装后生成的 `config.json` 或 `SpektraFilmLab-PS.ccx`**，它们含你的本机令牌。

## 更新

关闭正在进行的显影任务，再运行新版 `安装.command`。安装器复用已有本机令牌，更新引擎、资源和面板。重新打开 Photoshop 使新版插件脚本生效。原 RAW 和 PS 文档不在安装器的操作范围内。

## 常见问题

**没有找到 Adobe 插件安装器**：安装或修复 Creative Cloud 桌面程序，并先正常启动一次 Photoshop。安装依赖 Adobe 官方 UPIA，不使用手工修改 Photoshop 安全设置的方式。

**端口 49321 已被占用**：关闭旧版 FilmLab 引擎或占用该端口的程序，再点启动。安装器不会强行杀掉身份不明的进程。开发阶段旧“FilmLab 胶片实验室”和这个公开版是不同插件 ID，旧引擎需先退出。

**安装器已生成 CCX，但 Adobe 安装失败**：可双击 `~/Library/Application Support/SpektraFilmLab PS/SpektraFilmLab-PS.ccx` 重试。这个文件只给本机用。

**面板显示引擎未连接**：先启动引擎，再点面板“连接引擎”。日志位于同一 Application Support 目录的 `engine.log`。提交问题时不要附照片、配置令牌或完整 EXIF；先提供系统/PS版本、图片尺寸和错误文字。

**某台相机 RAW 打不开**：Apple RAW 支持随 macOS 更新，以系统解码器支持的机型为准；可先在 PS 打开 RGB 8/16 位图，再用“读取 PS 图像”。该入口没有 RAW 白平衡。

**日期没有显示**：查看日期后背的提示。没有 EXIF 日期时改用手动日期；宽幅无日期后背，120 需要片边，数据行需要有拍摄元数据。

**想卸载**：先停止引擎，在 Creative Cloud 的插件管理中移除 SpektraFilmLab PS；确认不再需要后移除其 Application Support 目录。本版不安装系统级服务或登录项。
