<div align="center">

<img src="icon.png" alt="TinyMirror 图标" width="128" height="128">

# TinyMirror

**通过 Wi‑Fi 将 iPhone 屏幕投射到 Mac。**

[![许可证：GPL v3](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![平台：macOS 26+](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg)](#系统要求)
[![最新版本](https://img.shields.io/github/v/release/lingmacker/TinyMirror)](https://github.com/lingmacker/TinyMirror/releases/latest)

**中文** · [English](README.en.md)

</div>

TinyMirror 可以将 Mac 变成无线投屏接收器。它会像 Apple TV 一样出现在
iPhone 控制中心的**屏幕镜像**列表中。选择它后，iPhone 画面会显示在 Mac 的原生窗口中，
无需在 iPhone 上安装任何应用。

TinyMirror 接收画面与声音，不支持从 Mac 向 iPhone 转发鼠标或键盘操作。

---

## 安装

从 **[Releases](https://github.com/lingmacker/TinyMirror/releases/latest)** 下载最新的 `.dmg`，
打开后将 TinyMirror 拖入“应用程序”文件夹。

构建产物使用 **ad-hoc 签名**，不是 Developer ID 签名，也没有经过 Apple 公证。
其他 Mac 下载的副本可能会被 Gatekeeper 拦截。只打开你信任的构建版本；如果 macOS 阻止启动，
请在“系统设置 → 隐私与安全性”中明确批准，不要关闭 Gatekeeper。

TinyMirror 运行在**菜单栏**中，不显示 Dock 图标。手机连接后，投屏窗口会自动打开；
随时选择 **显示投屏窗口** 可以查看连接说明。首次启动时 macOS 会请求**本地网络权限**，
没有该权限就无法投屏。

然后在 iPhone 上选择：**控制中心 → 屏幕镜像 →“‹你的 Mac› (TinyMirror)”**。

### 系统要求

| | |
|---|---|
| **macOS** | 26（Tahoe）或更高版本，支持 Apple 芯片和 Intel |
| **iPhone** | 与 Mac 连接到同一 Wi‑Fi 的任意 iPhone |
| **投屏所需** | 无其他依赖，无需在手机端安装应用 |

## 投屏窗口

画面位于纤薄的 5 点石墨色边框中，带有柔和圆角和原生窗口阴影。全屏时会移除边框，
显示为无边缘画面。窗口默认隐藏关闭、最小化和全屏按钮；将鼠标移到左上角附近即可显示，
离开该区域后重新隐藏。鼠标悬停在画面其他位置不会显示按钮。VoiceOver 仍可访问这些按钮。
按 **Escape** 退出全屏。

即使尚未连接手机，也可以在菜单栏选择 **显示投屏窗口** 查看连接说明。等待页面会一直显示，
直到第一帧视频真正准备好，不会出现空白黑屏。关闭窗口只会隐藏它。选择菜单栏中的
**停止投屏**，或在 iPhone 控制中心停止投屏，即可断开连接。该操作会先退出全屏、清除并隐藏画面，
然后让接收器重新可用，不会退出 TinyMirror。

新显示的投屏窗口会在屏幕中央打开；移动或调整可见窗口的大小不会强制它回到中央。空闲时窗口使用
9:18 的手机比例画布；连接后会按照设备的实际比例显示，断开后恢复默认手机比例。

拖动标题栏或画面可以移动窗口。调整大小时会保持当前画布比例；同方向的视频比例或分辨率变化只在窗内等比适配，不会重置窗口大小。横竖方向切换时，窗口会保留手动选定的尺度并适配屏幕边界，不裁切画面。

在菜单栏选择 **窗口置顶**，可以让投屏窗口浮在其他应用上方。该选项默认开启，并会在重启后保留。

投屏窗口处于活动状态时：**⌘M** 显示窗口，**⌘⇧M** 停止投屏，**⌘T** 切换窗口置顶，
**⌘Q** 退出 TinyMirror。这些是应用快捷键，不是全局热键。

## 分辨率与画质

在菜单栏的 **分辨率** 菜单中选择 **720p**、**1080p**、**2K（1440p）**（默认）或 **4K**。
选择会被保存。修改前请先停止投屏，然后从 iPhone 重新连接；空闲时修改分辨率会重启接收器。
1440p 和 4K 会在 H.264 之外启用 HEVC，需要发送端支持和稳定的网络；它们只是请求，不保证实际协商成功。
投屏过程中菜单会显示实际接收的像素尺寸和编码格式。

AirPlay 使用请求的显示高度协商视频流。例如，竖屏手机在 1080p 预设下可能发送约 498×1080 的画面，
而不是 1920×1080 的横屏画面。放大图片无法恢复缺失的细节；只有手机实际发送更多像素时，更高预设才会有帮助。
码率和压缩质量仍由 iOS 控制。

### 投屏帧率

菜单栏的 **投屏帧率** 提供 **30 FPS**（默认）和 **60 FPS**，选择会被保存。
停止投屏后修改，再从 iPhone 重新连接生效。该选项请求最高发送帧率，并非强制锁帧；
实际帧率仍由 iPhone、画面内容和网络决定。60 FPS 需要更多带宽与解码资源。

## 声音

投屏音频通过 Mac 当前默认的扬声器、耳机或其他系统输出设备播放，无需麦克风权限。
支持 44.1 kHz 双声道的 AAC-ELD、AAC-LC、ALAC 和 16 位 PCM，由系统解码；画面和声音使用同一个播放时钟。
可通过 iPhone 播放音量与 Mac 系统音量调整声音。停止投屏、断开连接或退出后会清空音频缓冲。
单独投送 ALAC 音频使用 120 毫秒短排程缓冲（屏幕镜像仍为 80 毫秒），不额外叠加秒级播放延迟。起播、停播和重传中的有效压缩静音帧会正常解码，不按包长丢弃；屏幕镜像的低延迟策略不变。

TinyMirror 会播放手机持续发送的声音，无法获知手机上哪个应用在前台。若应用切到后台仍有声音，请在手机端暂停或检查应用的后台／小窗播放设置；也可以停止投屏。

如果某个应用没有向 AirPlay 发送音频，或内容受 DRM 保护，TinyMirror 无法为它补出声音。
网络抖动与蓝牙输出设备也可能增加延迟；遇到明显音画不同步时，请先用 Mac 扬声器或有线耳机重试。

## 语言

应用支持**英文**和**简体中文**，跟随 macOS 的系统或应用语言设置。其他语言会回退到英文。
菜单项、连接和错误提示、辅助功能说明以及本地网络权限提示均已本地化。设备名称和 TinyMirror 名称不会翻译。
在系统设置中修改语言后，请重新启动应用。

## 已知限制

安装前请注意，以下部分限制是长期存在的：

- **受保护的内容受限。** DRM 视频和音频可能黑屏或静音。
- **不支持远程操控。** 不支持触控、键盘和鼠标转发。
- **不支持 Mac App Store。** App Store 不接受此 AirPlay 实现及 GPL 许可代码，因此只能直接下载使用。

## 故障排查

**菜单栏图标没有出现。** 在带刘海的 Mac 上，macOS 可能会把新状态项放到**刘海后面**，
导致它不可见、不可点击，即使旁边还有空位。TinyMirror 首次启动时会预设菜单栏位置以避免这种情况。
如果图标仍然不见，说明菜单栏确实已满，请退出一两个菜单栏应用。之后可以按住 ⌘ 拖动图标，位置会被记住。

使用 `TINYMIRROR_DEBUG=1` 启动应用，可以查看图标的具体位置以及是否位于刘海后面。

**控制中心没有出现投屏目标。** 确认两台设备连接到同一网络，并在“系统设置 → 隐私与安全性 → 本地网络”中允许 TinyMirror 访问本地网络。

## 从源码构建

需要 Xcode、CMake 3.22+ 和 Homebrew 的 `pkg-config`（`pkgconf`）：

```sh
brew install cmake pkg-config
```

首次构建会下载经过 SHA-256 校验的 OpenSSL 3.5.9 和 libplist 2.8.0 源码，并在
`.build/deps/macos26` 下为 macOS 26 构建静态库。首次构建需要网络，耗时也会比增量构建更长。
不会使用 Homebrew 的 OpenSSL/libplist 二进制包，因为较新的 bottle 可能要求更高版本的 macOS。
如果删除了 `.build/` 或本地依赖，`make build` 会自动重新创建并刷新 CMake 的依赖路径。
`bootstrap.sh` 还会幂等应用 `native/patches/uxplay-audio-silence.patch`，修复镜像静音占位包阻塞音频重排的问题；真实丢包仍会请求重传。

```sh
make build    # 获取固定版本的 UxPlay，增量构建 native core 和 Debug 应用
make run      # 构建并启动 dist/TinyMirror.app
make install  # 构建 Debug 版本并安装到 /Applications/TinyMirror.app
make clean    # 删除构建产物、dist/ 和 native/build/
```

使用 `bash scripts/check-media.sh` 运行静音回归检查：覆盖原生 RTP 静音占位、重传、序号回绕、256 包突发收包，以及系统音频解码、双声道纯音波形、视频显示、音量、停止清理和窗口尺寸稳定性。用例生成测试音频，不采集用户声音，详见 [Tests/README.md](Tests/README.md)。

`make` 默认执行 `build`。安装复用 `build` 目标，默认构建 Debug；可用 `CONFIGURATION=release` 指定 Release。使用
`make install INSTALL_DIR="$HOME/Applications"` 可以指定其他已存在的安装目录。执行 `run` 或 `install` 前请退出正在运行的 TinyMirror；
这些目标不会替你终止正在进行的投屏，安装也不会自动使用 `sudo`。

每次构建都会将可执行文件、可替换的 native 库、本地化资源、权限元数据、图标和许可证组装到
`dist/TinyMirror.app`。本地 App 和打包脚本生成的磁盘映像均使用 ad-hoc 签名，不需要 Apple 账号、
签名证书、钥匙串身份或公证服务。安装直接使用 `cp -Rf` 强制覆盖，不提供失败回滚，
也不会删除旧版本独有的文件；不会修改用户偏好设置。

`make clean` 会删除 `.build/`、`dist/` 和 `native/build/`，包括本地依赖、依赖源码、SwiftPM 配置和 native CMake 缓存。
下次构建会自动恢复这些内容。

### 发布

生成 Release 应用和磁盘映像：

```sh
./scripts/package.sh                 # -> dist/TinyMirror.app + dist/TinyMirror-<ver>.dmg
VERSION=0.2.0 ./scripts/package.sh
```

推送版本标签（例如 `v0.2.0`）会触发 GitHub Actions，在 macOS 26 runner 上自动构建并发布
`TinyMirror-0.2.0.dmg` 到 GitHub Releases。发布工作流位于 `.github/workflows/release.yml`。

`package.sh` 会执行 `make build CONFIGURATION=release`，使用同一套应用组装流程，然后创建并签名磁盘映像。
Ad-hoc 签名只提供代码完整性，不证明开发者身份，也不等同于公证，因此 Gatekeeper 可能阻止带隔离属性的下载文件。
旧的 `NOTARIZE=1` 选项现在会明确失败；ad-hoc 构建不能提交给 Apple 公证。

## 工作原理

```text
iPhone ──(AirPlay：Bonjour + 配对 + FairPlay + RTSP)──▶ libMirrorCore.dylib
                                                       ├─ H.264/HEVC ─▶ VideoPipeline
                                                       └─ 音频包 ────▶ AirPlayAudioFormat
                                                                         │
                                                               MediaPlayback（系统解码、音画同步）
                                                               ├─ 原生投屏窗口
                                                               └─ Mac 默认音频输出
```

- **`native/`**：`mirror_bridge.c` 将 vendored AirPlay 协议核心封装为简洁的 C API（`mb_start_video_with_fps`、兼容的
  `mb_start_video` / `mb_start` 和 `mb_stop`），由 `make build`（通过 `native/build.sh`）构建为 `libMirrorCore.dylib`。
  所有第三方代码只位于这里。
- **`Sources/TinyMirror/`**：应用本身，包括菜单栏、原生投屏窗口、`VideoPipeline` 视频封装、
  `AirPlayAudioFormat` 音频封装，以及使用 `AVSampleBufferRenderSynchronizer` 统一音画时钟的 `MediaPlayback`。音频和视频均由系统解码。
- **`Sources/TinyMirror/Resources/`**：集中存放 `Info.plist`、本地化文案、应用图标和菜单栏资源。`AppIcon.icon/` 中的黑白橘「叠幕」由 Xcode 的 `actool` 编译为原生图标栈和 `.icns`；`Assets.xcassets/` 提供 18 点菜单栏单色模板，未连接时双框空心，连接后前框实心。可编辑菜单栏源文件为 `MenuBarIcon*.svg`，根目录的 `icon.png` 用于文档展示。
- **`vendor/`**：[UxPlay](https://github.com/FDH2/UxPlay) 的源码目录，由 `scripts/bootstrap.sh` 按固定 commit 获取，不提交到仓库。

## 路线图

- [x] 音频播放（AAC-ELD / AAC-LC / ALAC / PCM）与统一音画时钟
- [x] H.265/HEVC 支持和可选分辨率请求

欢迎贡献代码。

## 许可证

GPL-3.0，详见 [LICENSE](LICENSE)。

TinyMirror 使用 GPL-3.0，是因为它依赖的 FairPlay 握手实现 `playfair` 使用 GPL-3.0，且无法移除：
`fairplay_decrypt()` 会恢复媒体密钥，没有它就无法建立投屏会话。

第三方组件全部位于 `libMirrorCore.dylib` 中：

| 组件 | 来源 | 许可证 |
|---|---|---|
| AirPlay/RAOP 核心 | UxPlay `lib/` | LGPL-2.1-or-later |
| `playfair`（FairPlay） | UxPlay `lib/playfair/` | GPL-3.0 |
| llhttp | UxPlay `lib/llhttp/` | MIT |
| libplist | libimobiledevice | LGPL-2.1-or-later |
| libcrypto | OpenSSL 3 | Apache-2.0 |

LGPL 的重新链接义务通过结构设计满足：这些组件位于可替换的共享库中，只导出 `mb_*` 桥接 API，
任何人都可以使用 `./native/build.sh` 重新构建并替换自己的版本。详见 [licenses/NOTICE.md](licenses/NOTICE.md)。

### 关于 FairPlay

FairPlay 这个名称指代两种不同的东西，需要区分：

**FairPlay Streaming** 是 Netflix、Disney+ 和 Apple TV+ 使用的内容 DRM，需要硬件密钥。
TinyMirror 没有这些密钥，也无法获取它们；受保护的视频会像在其他第三方接收器上一样显示为黑屏。
iOS 会在编码前将受保护图层排除在镜像画面之外，所以这是手机端的限制，不是 TinyMirror 实现的限制。

**FairPlay SAP** 是会话握手协议，由 `playfair` 实现。它响应认证挑战，让手机释放**自己的屏幕**所需的密钥。
`fairplay_decrypt()` 会把手机在建立会话时发送的 72 字节密钥转换成投屏流使用的 16 字节 AES 密钥。
它不是可选功能；没有它，任何投屏会话都无法启动。

因此 TinyMirror 不会解密任何受版权保护的作品。它只是完成协议认证，让设备在设备所有者的电脑上显示自己的屏幕。
所有开源 AirPlay 接收器都依赖同一握手协议，商业产品也需要逆向实现它。

本项目参考了 [UxPlay](https://github.com/FDH2/UxPlay) 和 [RPiPlay](https://github.com/FD-/RPiPlay)：

> 本项目基于公开可用的信息构建，仅用于教育目的。用户有责任遵守当地法律。
> 本项目依赖用于 FairPlay 握手的第三方 GPL 库，其法律地位并不明确。
> 如果你代表 Apple 并反对该库或其在本项目中的使用，请提交 issue 或联系维护者，以便采取适当措施。

---

本项目建立在 [UxPlay](https://github.com/FDH2/UxPlay) 的工作之上，其 AirPlay 实现使投屏成为可能。
本项目与 Apple Inc. 没有关联，也未获得 Apple Inc. 的认可。
