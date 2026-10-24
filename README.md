# Auraliscope

**English** · [中文](#中文) · [한국어](#한국어)

**Real-time loudness, spectrum and soundstage analysis for macOS: stereo to 9.1.6, live or from a file.**

Auraliscope shows loudness, levels, spectrum, spectrogram, waveform and the spatial image of your audio in one window
while you listen. Meter any input, anything your Mac plays, or a DAW track through the Auraliscope Bridge plugin.
Analyse a whole file and get a printable loudness and master report.

[Download](https://github.com/jinboz12/Auraliscope/releases) · [What's new in 2.0 RC 2](docs/2.0_RC2_RELEASE_NOTES.md) ·
[Full update log](docs/UPDATE_LOG_since_1.2.2.md) · [Report an issue](https://github.com/jinboz12/Auraliscope/issues)

> **Status:** 2.0 RC 2 (build 118) is a release candidate. The app and plugins are ad hoc signed. The installer is
> unsigned and not notarized.

## Features

**Loudness.** Momentary, short-term and integrated LUFS, loudness range, true peak and a VU meter. Readings are
checked against 14 delivery standards or your own target and ceiling, which you can type in directly. Options include
LU or LUFS, EBU +9/+18 scales, an overs counter and history from 15 s to the whole session. Passes EBU Tech 3341 and
3342 test cases.

**Spectrum and spectrogram.** One logarithmic frequency axis with a piano keyboard and note names on hover. The
display offers colour maps, Enhanced (reassigned) and 3D views, peak holds and an average spectrum. The optional
**Multi-FFT Spectrum (Beta)** fuses three FFT sizes into one calibrated curve, sharp in the bass and fast in the treble.

**Soundstage.** Stereo shows a stereometer (full band, 3 or 5 bands) with balance, width and per-band correlation.
Immersive shows a dome you can orbit, where each frequency band glows where its speakers place it. Formats go up to
9.1.6, or you can define your own speaker layout.

**Levels and waveform.** Peak and RMS per channel with holds and over warnings. Exact sample-peak waveforms over
2, 4 or 8 s.

**File analysis and reports.** Analyze Audio File… (⌘O) measures WAV, AIFF, CAF, MP3, AAC, ALAC, FLAC and more,
mono to 9.1.6. A five-minute file takes about two seconds. Export a four-page loudness and master report as PDF or
CSV for files or live sessions (⌘E).

**Auraliscope Bridge (VST3 / AU).** Insert it on a track or bus, from stereo up to 9.1.6 buses. It analyses inside
the DAW and passes the audio through unchanged. Pause and Reset reach the plugin too.

**Sources.** Any Core Audio input, or, on macOS 14.2+, any output through a process tap, without changing or
delaying the sound. Up to 64 channels can be routed to speaker roles. Routing follows Audio MIDI Setup, with a
Channel Order menu for SMPTE, Film (Pro Tools) and VST3 (Nuendo/Cubase) orders.

**Your layout.** Enlarge any panel (⌘1–⌘7), open it in its own window or hide it. Save layouts, or use **Dock mode**
(⌥⌘S) for a row of meters along the bottom of the screen. Settings presets are saved as files you can copy to
another Mac.

**Look and language.** Light and Dark, a dozen colour themes plus the hardware-style Studio Console, and ProMotion
120 fps. The interface is in English, 简体中文, 繁體中文, 한국어, 日本語 and Español.

**Updates.** Check for Updates looks at this repository's releases. Turn on **Include pre-releases** in Settings ▸
General to also get betas and release candidates.

## Requirements

| | |
| --- | --- |
| App | Apple silicon Mac, macOS 13 or later |
| Output capture | macOS 14.2 or later, System Audio Recording permission |
| Plugins | VST3 and AU, macOS 11 or later, Apple silicon and Intel |
| Display | 1280 × 720 or larger |

## Install

1. Download `Auraliscope 2.0 rc 2 build 118.pkg` from [Releases](https://github.com/jinboz12/Auraliscope/releases).
2. Quit Auraliscope and your DAW. Open the package and choose the app, VST3 and/or Audio Unit.
3. Open Auraliscope from Applications, allow audio access when asked, and pick a source.

The installer replaces any 2.0 build and keeps your settings. If macOS blocks the first launch, open
**System Settings ▸ Privacy & Security** and choose **Open Anyway**. See [installation](docs/INSTALLATION.md).

## Privacy

Audio is analysed in memory on your Mac, in real time. Auraliscope never records audio to a file or uploads it. It
asks only for the permission the chosen source needs: Microphone for an input, System Audio Recording for an output.
Update checks are anonymous requests to GitHub's public API, made only when you ask.

## Build from source

macOS 13+, Xcode with Swift 6. See [source distribution](docs/SOURCE_DISTRIBUTION.md) for details.

```sh
Bridge/scripts/fetch-sdks.sh      # pinned VST3/AU SDKs
scripts/test.sh                   # core, kernel and localization checks
Bridge/scripts/build-app.sh
Bridge/scripts/build-plugins.sh
Bridge/scripts/package-installer.sh
```

| Folder | Contents |
| --- | --- |
| `Sources/Auraliscope` | The app (SwiftUI, Metal) |
| `Sources/AnalysisCore`, `Sources/AnalysisKernels` | Shared DSP used by the app and the plugins |
| `Sources/BridgeTransport`, `Bridge/` | Plugin, transport protocol and their tools ([architecture](Bridge/ARCHITECTURE.md), [protocol](Bridge/PROTOCOL.md)) |
| `docs/` | Release notes, update log, installation, loudness references, licences |

## Feedback

Please report problems on [GitHub Issues](https://github.com/jinboz12/Auraliscope/issues). Include the version and
build, your macOS version and Mac, the audio device, the channel layout and the steps to reproduce. Help ▸ Show
Diagnostic Logs opens the app's event logs, which contain no audio. Questions and ideas are also welcome on the
Discord linked in Settings ▸ General ▸ Feedback.

## License

Copyright © 2026 JINBOZ. Licensed under **GPL-3.0-only**. See [LICENSE](LICENSE), [COPYRIGHT.md](COPYRIGHT.md),
[third-party notices](docs/THIRD_PARTY_NOTICES.md) and [image rights](docs/ASSET_RIGHTS.md). Official installers may
be sold. You keep your GPL rights to use, change, build and share the source and binaries.

The software is provided "as is", without warranty of any kind. Loudness standard and service names belong to
their owners.

---

<a id="中文"></a>

# Auraliscope（中文）

[English](#auraliscope) · **中文** · [한국어](#한국어)

**macOS 实时响度、频谱与声场分析：立体声至 9.1.6，实时或分析文件。**

Auraliscope 在一个窗口中显示响度、电平、频谱、频谱图、波形和声像，让你边听边看。可以测量任意输入设备、Mac 正在播放的声音，
或通过 Auraliscope Bridge 插件测量 DAW 中的轨道。也可以分析整个文件，并导出可打印的响度与母带报告。

[下载](https://github.com/jinboz12/Auraliscope/releases) · [2.0 RC 2 更新内容](docs/2.0_RC2_RELEASE_NOTES.md) ·
[完整更新日志](docs/UPDATE_LOG_since_1.2.2.md) · [反馈问题](https://github.com/jinboz12/Auraliscope/issues)

> **状态：** 2.0 RC 2（build 118）为候选版本。应用与插件使用 ad hoc 签名，安装包未签名、未公证。

## 功能

**响度：** 瞬时、短期与整合 LUFS、响度范围、真峰值和 VU 表。可按 14 种交付标准或自定义目标与上限判断，目标值可直接输入。
支持 LU/LUFS、EBU +9/+18 刻度、过载计数，以及从 15 秒到整个会话的历史。通过 EBU Tech 3341 与 3342 测试用例。

**频谱与频谱图：** 统一的对数频率轴，配钢琴键盘，悬停显示音名；提供色图、增强（重分配）与 3D 视图、峰值保持和平均频谱。
可选的 **Multi-FFT 频谱（Beta）** 将三种 FFT 长度融合为一条校准曲线：低频清晰、高频快速。

**声场：** 立体声模式为声像仪（全频、3 段或 5 段），带平衡、宽度和分频段相关性；沉浸声模式为可环绕查看的穹顶，
每个频段在其扬声器所定位的方向发光。支持至 9.1.6 的格式，也可以自定义扬声器布局。

**电平与波形：** 每声道峰值与 RMS，带保持和过载提示；2/4/8 秒精确采样峰值波形。

**文件分析与报告：** 分析音频文件…（⌘O）支持 WAV、AIFF、CAF、MP3、AAC、ALAC、FLAC 等格式，单声道至 9.1.6，
五分钟的文件约两秒完成。文件或实时会话（⌘E）都可以导出四页的响度与母带报告（PDF 或 CSV）。

**Auraliscope Bridge（VST3 / AU）：** 插入轨道或总线（立体声至 9.1.6），在 DAW 内分析，音频原样通过；暂停与重置同样作用于插件。

**音源：** 任意 Core Audio 输入；macOS 14.2 起可通过进程 tap 测量任意输出，不改变也不延迟声音。最多 64 个声道可路由到扬声器位置。
路由跟随「音频 MIDI 设置」，并提供 SMPTE、Film（Pro Tools）与 VST3（Nuendo/Cubase）声道顺序菜单。

**自定义布局：** 任意面板可放大（⌘1–⌘7）、在独立窗口打开或隐藏；可保存布局，或使用 **Dock 模式**（⌥⌘S）在屏幕底部排成一行。
设置预设以文件保存，可复制到其他 Mac。

**外观与语言：** 浅色/深色、十余种配色及硬件风格的 Studio Console，支持 ProMotion 120 fps。界面提供 English、简体中文、
繁體中文、한국어、日本語 和 Español。

**更新：** 「检查更新」读取本仓库的 Releases。在设置 ▸ 通用中打开 **包含预发布版本**，即可同时获取测试版和候选版本。

## 系统要求

| | |
| --- | --- |
| 应用 | Apple 芯片 Mac，macOS 13 或更高版本 |
| 输出捕获 | macOS 14.2 或更高版本，需「系统音频录制」权限 |
| 插件 | VST3 与 AU，macOS 11 或更高版本，Apple 芯片与 Intel |
| 显示器 | 1280 × 720 或更大 |

## 安装

1. 从 [Releases](https://github.com/jinboz12/Auraliscope/releases) 下载 `Auraliscope 2.0 rc 2 build 118.pkg`。
2. 退出 Auraliscope 和 DAW，打开安装包，选择应用、VST3 和/或 Audio Unit。
3. 从「应用程序」打开 Auraliscope，按提示允许音频访问，然后选择音源。

安装包会原位替换任何 2.0 版本，并保留你的设置。如果 macOS 阻止首次打开，请前往 **系统设置 ▸ 隐私与安全性**，选择 **仍要打开**。
参阅[安装说明](docs/INSTALLATION.md)。

## 隐私

音频只在你的 Mac 内存中实时分析，Auraliscope 不会把音频录成文件，也不会上传。它只请求所选音源需要的权限：输入设备需要「麦克风」，
输出需要「系统音频录制」。只有在你主动检查更新时，才会向 GitHub 公共 API 发送匿名请求。

## 从源码构建

需要 macOS 13 或更高版本，以及带 Swift 6 的 Xcode。详见[源码分发说明](docs/SOURCE_DISTRIBUTION.md)。

```sh
Bridge/scripts/fetch-sdks.sh
scripts/test.sh
Bridge/scripts/build-app.sh
Bridge/scripts/build-plugins.sh
Bridge/scripts/package-installer.sh
```

## 反馈

请在 [GitHub Issues](https://github.com/jinboz12/Auraliscope/issues) 报告问题，并附上版本与 build、macOS 版本与机型、音频设备、
声道布局和复现步骤。帮助 ▸ 显示诊断日志可打开应用的事件日志（不含音频）。也欢迎在设置 ▸ 通用 ▸ 反馈中的 Discord 交流。

## 许可

Copyright © 2026 JINBOZ。以 **GPL-3.0-only** 授权。参阅 [LICENSE](LICENSE)、[COPYRIGHT.md](COPYRIGHT.md)、
[第三方声明](docs/THIRD_PARTY_NOTICES.md)和[图像权利记录](docs/ASSET_RIGHTS.md)。官方安装包可能收费，但你仍享有 GPL 赋予的使用、修改、
构建和分享源码与二进制文件的权利。本软件按「原样」提供，不附带任何担保。响度标准与服务名称归其各自所有者。

---

<a id="한국어"></a>

# Auraliscope (한국어)

[English](#auraliscope) · [中文](#中文) · **한국어**

**macOS용 실시간 라우드니스·스펙트럼·사운드스테이지 분석: 스테레오부터 9.1.6까지, 실시간 또는 파일로.**

Auraliscope는 라우드니스, 레벨, 스펙트럼, 스펙트로그램, 파형과 공간 이미지를 한 창에 보여 주어 들으면서 볼 수 있게 합니다.
입력 장치, Mac에서 재생 중인 소리, 또는 Auraliscope Bridge 플러그인을 통해 DAW 트랙을 측정할 수 있습니다. 파일 전체를 분석해
인쇄 가능한 라우드니스·마스터 보고서도 만들 수 있습니다.

[다운로드](https://github.com/jinboz12/Auraliscope/releases) · [2.0 RC 2 새 기능](docs/2.0_RC2_RELEASE_NOTES.md) ·
[전체 업데이트 기록](docs/UPDATE_LOG_since_1.2.2.md) · [문제 보고](https://github.com/jinboz12/Auraliscope/issues)

> **상태:** 2.0 RC 2(build 118)는 릴리스 후보입니다. 앱과 플러그인은 ad hoc 서명되었고, 설치 패키지는 서명 및 공증되지 않았습니다.

## 기능

**라우드니스:** 순간·단기·통합 LUFS, 라우드니스 범위, 트루 피크, VU 미터. 14개 납품 표준이나 직접 입력한 목표와 상한으로 판정합니다.
LU/LUFS, EBU +9/+18 눈금, 오버 카운터, 15초부터 세션 전체까지의 기록을 지원하며 EBU Tech 3341·3342 테스트 케이스를 통과합니다.

**스펙트럼과 스펙트로그램:** 피아노 건반이 있는 하나의 로그 주파수 축과 마우스오버 음 이름. 컬러 맵, 강화(재할당) 및 3D 보기,
피크 홀드, 평균 스펙트럼을 제공합니다. 선택형 **Multi-FFT 스펙트럼(베타)**은 세 가지 FFT 크기를 하나의 보정된 곡선으로 합쳐
저역은 선명하고 고역은 빠르게 보여 줍니다.

**사운드스테이지:** 스테레오는 밸런스, 폭, 대역별 상관도를 갖춘 스테레오미터(전체, 3 또는 5 대역). 이머시브는 돌려 볼 수 있는
돔으로, 각 주파수 대역이 스피커가 배치한 방향에서 빛납니다. 9.1.6까지의 포맷과 사용자 스피커 레이아웃을 지원합니다.

**레벨과 파형:** 채널별 피크와 RMS, 홀드와 오버 경고. 2/4/8초 정확한 샘플 피크 파형.

**파일 분석과 보고서:** 오디오 파일 분석…(⌘O)은 WAV, AIFF, CAF, MP3, AAC, ALAC, FLAC 등을 모노부터 9.1.6까지 측정하며,
5분 파일을 약 2초에 분석합니다. 파일이나 실시간 세션(⌘E)의 4페이지 라우드니스·마스터 보고서를 PDF 또는 CSV로 내보냅니다.

**Auraliscope Bridge(VST3 / AU):** 트랙이나 버스(스테레오부터 9.1.6)에 삽입하면 DAW 안에서 분석하고 오디오는 그대로 통과합니다.
일시정지와 재설정은 플러그인에도 적용됩니다.

**소스:** 모든 Core Audio 입력, macOS 14.2 이상에서는 프로세스 탭으로 모든 출력을 소리 변경이나 지연 없이 측정합니다. 최대 64채널을
스피커 역할에 라우팅할 수 있습니다. 라우팅은 오디오 MIDI 설정을 따르며 SMPTE, Film(Pro Tools), VST3(Nuendo/Cubase) 채널 순서
메뉴를 제공합니다.

**나만의 레이아웃:** 패널 확대(⌘1–⌘7), 별도 창으로 열기, 숨기기. 레이아웃을 저장하거나 **Dock 모드**(⌥⌘S)로 화면 아래에 한 줄로
배치합니다. 설정 프리셋은 파일로 저장되어 다른 Mac으로 복사할 수 있습니다.

**모양과 언어:** 라이트/다크, 십여 가지 색상 테마와 하드웨어 스타일 Studio Console, ProMotion 120 fps. English, 简体中文,
繁體中文, 한국어, 日本語, Español을 지원합니다.

**업데이트:** 업데이트 확인은 이 저장소의 Releases를 확인합니다. 설정 ▸ 일반에서 **사전 출시 버전 포함**을 켜면 베타와 릴리스 후보도
받을 수 있습니다.

## 요구 사항

| | |
| --- | --- |
| 앱 | Apple 실리콘 Mac, macOS 13 이상 |
| 출력 캡처 | macOS 14.2 이상, 시스템 오디오 녹음 권한 |
| 플러그인 | VST3 및 AU, macOS 11 이상, Apple 실리콘과 Intel |
| 디스플레이 | 1280 × 720 이상 |

## 설치

1. [Releases](https://github.com/jinboz12/Auraliscope/releases)에서 `Auraliscope 2.0 rc 2 build 118.pkg`를 다운로드합니다.
2. Auraliscope와 DAW를 종료하고 패키지를 열어 앱, VST3, Audio Unit 중 원하는 항목을 선택합니다.
3. 응용 프로그램에서 Auraliscope를 열고 오디오 접근을 허용한 뒤 소스를 선택합니다.

설치 패키지는 기존 2.0 빌드를 교체하며 설정을 유지합니다. macOS가 첫 실행을 막으면 **시스템 설정 ▸ 개인정보 보호 및 보안**에서
**그래도 열기**를 선택하세요. [설치 안내](docs/INSTALLATION.md)를 참고하세요.

## 개인정보

오디오는 Mac의 메모리에서 실시간으로만 분석되며, Auraliscope는 오디오를 파일로 녹음하거나 업로드하지 않습니다. 선택한 소스에 필요한
권한만 요청합니다(입력은 마이크, 출력은 시스템 오디오 녹음). 업데이트 확인은 사용자가 요청할 때만 GitHub 공개 API로 익명 요청을 보냅니다.

## 소스에서 빌드

macOS 13 이상과 Swift 6이 포함된 Xcode가 필요합니다. 자세한 내용은 [소스 배포 안내](docs/SOURCE_DISTRIBUTION.md)를 참고하세요.

```sh
Bridge/scripts/fetch-sdks.sh
scripts/test.sh
Bridge/scripts/build-app.sh
Bridge/scripts/build-plugins.sh
Bridge/scripts/package-installer.sh
```

## 피드백

[GitHub Issues](https://github.com/jinboz12/Auraliscope/issues)에 문제를 알려 주세요. 버전과 빌드, macOS 버전과 Mac 기종,
오디오 장치, 채널 레이아웃, 재현 단계를 함께 적어 주세요. 도움말 ▸ 진단 로그 보기에서 앱의 이벤트 로그(오디오 없음)를 열 수 있습니다.
설정 ▸ 일반 ▸ 피드백의 Discord에서도 질문과 아이디어를 환영합니다.

## 라이선스

Copyright © 2026 JINBOZ. **GPL-3.0-only**로 배포됩니다. [LICENSE](LICENSE), [COPYRIGHT.md](COPYRIGHT.md),
[서드파티 고지](docs/THIRD_PARTY_NOTICES.md), [이미지 권리 기록](docs/ASSET_RIGHTS.md)을 참고하세요. 공식 설치 패키지는 유료일 수
있지만, 소스와 바이너리를 사용·수정·빌드·공유할 GPL 권리는 그대로 유지됩니다. 이 소프트웨어는 어떠한 보증 없이 "있는 그대로"
제공됩니다. 라우드니스 표준과 서비스 이름은 각 소유자에게 있습니다.
