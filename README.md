# Auraliscope

Auraliscope 是一款原生 macOS 音频电平与分析工具，用于实时监听输入和输出音频。

它将频谱、频谱图、波形、响度、声道电平、声场显示以及相关性分析整合在一个可自由调整大小的窗口中。

界面支持 **英语、简体中文和韩语**。

**当前公开候选版本：** 1.0.0rc（build 8）。。

## 功能

- 监听 Core Audio 输入设备；在 macOS 14.2 或更高版本中，也可通过 Core Audio Process Tap 监听系统输出。
- 支持最高 **9.1.6** 的多声道布局，并可将最多 **64 个物理声道**映射至不同扬声器角色。
- 提供以下实时音频分析功能：
  - 8192 点 L/R 频谱
  - 滚动频谱图（Spectrogram）
  - 每声道波形显示
  - 每声道 Peak / RMS 电平
  - LUFS
  - Loudness Range
  - True Peak
  - VU
  - 立体声相关性（Stereo Correlation）
- 支持跟随系统、浅色和深色三种外观模式。Dashboard 会保持其面板布局，并在系统支持时使用 macOS 原生 Liquid Glass 控件。
- 音频仅在内存中进行分析。应用不会保存或上传任何音频。

## 系统要求与权限

打包版本面向 **Apple Silicon**，理应要求 **macOS 13 或更高版本**。
**目前只在macOS 27.0 26A428 进行过测试**

输入监听需要获得 **麦克风（Microphone）** 权限。
输出监听需要 **macOS 14.2 或更高版本**，并需要 **系统音频录制（System Audio Recording）** 权限。
当所选输出的 Process Tap 开始捕获音频时，macOS 会自动请求该权限。

欢迎界面分别提供输入和输出音频源的权限操作入口。

应用不会请求以下权限：

- 屏幕画面录制
- 辅助功能（Accessibility）
- 自动化（Automation）
- 网络访问

## 本地构建

首先安装 Apple Command Line Tools，然后运行：

```sh
./scripts/test.sh
./scripts/package-app.sh
open "dist/1.0.0rc/Auraliscope.app"
```

打包脚本会生成：

```text
dist/1.0.0rc/Auraliscope.app
dist/1.0.0rc/Auraliscope-1.0.0rc-macOS.zip
```

当前脚本使用本地 **ad hoc 签名**。

这个 Release Candidate 版本采用 ad hoc 签名，仅用于测试，目前尚未经过 Apple notarization（公证）。因此，在其他 Mac 上运行时，macOS 可能会阻止应用启动。

如遇到阻止，可前往：

**系统设置 → 隐私与安全性**

并查看系统是否提供 **“仍要打开（Open Anyway）”** 选项。

如有需要，可以运行：

```sh
./scripts/brand-assets.sh
```

该脚本会使用以下文件重新生成应用图标：

```text
SoundmeterIcon/soundmeter Exports/soundmeter-macOS-Default-1024@1x.png
```


## 项目文件

- `Sources/Auraliscope/`：SwiftUI 界面、音频捕获、DSP 以及 Metal 渲染器。
- `Sources/AudioRing/`：C 语言音频回调及无锁缓冲区。
- `Resources/`：应用元数据、Entitlements、图标及三种本地化语言资源。
- `Tests/AuraliscopeTests/`：Core Audio 与 DSP 相关测试。
- `scripts/`：打包、资源生成、本地化检查以及测试脚本。
- `docs/THIRD_PARTY_NOTICES.md`：第三方组件署名及随项目提供的第三方许可证文本。

## License

2026 JINBOZ.
任何人均可免费下载、安装并运行Auraliscope 应用，用于自己的工作或私人用途。未明确授予的权利均予保留。第三方材料适用其各自的许可，详见第三方声明。本项目采用MIT库
