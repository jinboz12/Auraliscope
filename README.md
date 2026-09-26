# Auraliscope

**English** · [中文](#中文) · [한국어](#한국어)

**Real-time audio analysis and visualization for macOS.**

Auraliscope brings loudness, levels, spectrum, spectrogram, waveform, soundstage and stereo correlation together in one window, so you can see the dynamics, frequency balance and spatial image of what you hear while you listen.

It is made for music production, mixing, audio post-production, and for simply looking at what your Mac is playing.

[Download](https://github.com/jinboz12/Auraliscope/releases) · [Release notes](https://github.com/jinboz12/Auraliscope/releases/tag/v1.1) · [Report an issue](https://github.com/jinboz12/Auraliscope/issues)

## Features

### Loudness and dynamics

LUFS, loudness range (LRA), True Peak and a VU meter in one summary, read against a delivery target you choose (streaming, EBU R128, ATSC A/85, Netflix and more). The main reading can be Momentary, Short-term or Integrated loudness.

When True Peak goes over 0 dBTP, the summary shows the over and its size, so the peaks that need attention are easy to find.

### Channel levels

Peak and RMS for every channel, with peak holds and true-peak over warnings, so channels are easy to compare. Click a red clip light to clear the held over warnings.

### Spectrum, spectrogram and waveform

- **Spectrogram and spectrum** share one logarithmic frequency axis and a piano keyboard, showing the live spectrum beside its history. The keyboard lights the main pitches it detects, the notes sounding together. The panel can be mirrored in Settings to put the spectrum on the left.
- **Waveforms** per channel show amplitude and transients over 2, 4 or 8 seconds.

### Soundstage and correlation

Stereo and Immersive views show how the energy of each channel is placed in space. The Stereo soundstage is a stereometer that can draw the full band, 3 bands or 5 bands as dots, outlines or filled shapes. The Immersive soundstage is a lightweight 2D room for layouts from 3.0 to 9.1.6.

In Stereo, correlation is shown per frequency band, to help judge the relationship between left and right and the cancellation that can happen when they are summed to mono.

Mono mode is hidden by default and can be turned on in Settings.

> "Immersive" is this app's multichannel view. It does not encode, decode or certify Dolby Atmos.

### Input and output analysis

Auraliscope reads Core Audio input devices. On macOS 14.2 or later it can also analyse an output through a Core Audio process tap: what every app plays to it, without changing or delaying the signal.

At launch it meters the current macOS default output; any other source can be chosen at any time.

Layouts go up to 9.1.6, and up to 64 physical channels can be routed to any speaker role.

### Appearance and language

- System, Light and Dark appearances, with colour themes that tint every control.
- Works in a window or in full screen.
- Uses native Liquid Glass controls where the system supports them.
- English, Simplified Chinese and Korean.
- Settings changes preview immediately: Apply keeps them, Revert puts back what you had. Changing the language needs no restart, and the menu bar follows.

## Requirements

| | |
| --- | --- |
| Processor | Apple Silicon Mac |
| System | macOS 13 or later |
| Output capture | macOS 14.2 or later |
| Tested on | macOS 27.0 (26A428), MacBook Pro M1 Max |

The deployment target is not a guarantee that every version has been verified. Other macOS versions still need testing.

## Download and install

1. Download the DMG from the [Releases page](https://github.com/jinboz12/Auraliscope/releases).
2. Open the DMG and drag Auraliscope to the Applications folder.
3. Open Auraliscope from Applications.
4. Grant audio capture permission when asked, and choose the source to analyse.

The current release is **1.1 (build 51)**. It is ad hoc signed and not notarized by Apple. The download is `Auraliscope.dmg`, containing `Auraliscope.app`.

If macOS blocks the first launch, make sure the download came from this project's Releases page, then open **System Settings → Privacy & Security** and choose **Open Anyway**.

## Permissions and privacy

Auraliscope asks only for what the chosen source needs:

| Source | Permission |
| --- | --- |
| Input device | Microphone |
| Output audio | System Audio Recording |

The exact names of these permissions may differ between macOS versions.

**Audio is analysed in memory on your Mac, in real time. Auraliscope never saves captured audio to a file or uploads it.**

## Tips

- Before analysing, check that the device, channel layout and routing match your actual audio path.
- For multichannel audio, check how physical channels are mapped to speaker roles.
- Correlation helps judge stereo compatibility; confirm it by listening in mono.
- The soundstage shows the energy relationships between channels in the signal. It is not a measurement of room acoustics or of a real speaker setup.

## Feedback

Issues and suggestions are welcome on [GitHub Issues](https://github.com/jinboz12/Auraliscope/issues).

To help reproduce a problem, please include:

- the Auraliscope version and build;
- the macOS version and Mac model;
- the audio device and whether you are metering an input or an output;
- the channel layout and routing;
- steps to reproduce, what you expected and what happened;
- screenshots or a screen recording if useful.

Help ▸ Show Diagnostic Logs opens the app's event-only logs (never audio). Check any material for private information before posting it.

## License

Copyright © 2026 JINBOZ.

Anyone may download, install and run Auraliscope free of charge for their own work or private use. Under CC BY-NC-ND 4.0, you may share unmodified copies of this project for non-commercial purposes, following the terms of the license.

### Disclaimer

This software is provided "as is", without warranty of any kind, express or implied. To the extent permitted by applicable law, the author is not liable for any loss arising from its use. Third-party components and materials included in Auraliscope are subject to their own licenses.

The spectrogram's dB legend and time and frequency markings take their design cues from [AudioSpectrogram](https://github.com/lmshao/AudioSpectrogram). Auraliscope's real-time analysis and rendering are an independent implementation in Swift, Accelerate and Metal, and do not link that project's Rust library.

---

<a id="中文"></a>

# Auraliscope（中文）

[English](#auraliscope) · **中文** · [한국어](#한국어)

**为 macOS 打造的实时音频分析与可视化工具。**

Auraliscope 将响度、电平、频谱、频谱图、波形、声场和立体声相关性整合在一个窗口中，帮助你在聆听的同时观察声音的动态、频率分布与空间关系。

适用于音乐制作、混音、音频后期，以及日常播放与监听中的音频观察。

[下载应用](https://github.com/jinboz12/Auraliscope/releases) · [更新日志](https://github.com/jinboz12/Auraliscope/releases/tag/v1.1) · [反馈问题](https://github.com/jinboz12/Auraliscope/issues)

## 主要功能

### 响度与动态

集中查看 LUFS、响度范围（LRA）、真峰值（True Peak）与 VU 读数，并以你选择的交付标准（流媒体、EBU R128、ATSC A/85、Netflix 等）为目标。主响度读数可选瞬时、短期或积分响度。

真峰值超过 0 dBTP 时，界面会显示超限情况及具体数值，方便定位需要关注的峰值。

### 声道电平

独立显示各声道的 Peak 与 RMS 电平，并提供峰值保持与真峰值超限提示，便于比较声道之间的电平关系。点按红色削波灯即可清除保持的超限警告。

### 频谱、频谱图与波形

- **频谱图与频谱**：共用对数频率轴和钢琴键盘，显示实时频谱与其历史；键盘会点亮检测到的主要音高，即同时发声的音符。可在设置中镜像面板，把频谱移到左侧。
- **声道波形**：观察振幅与瞬态，可选 2、4 或 8 秒的范围。

### 声场与相关性

支持立体声与沉浸声显示模式，以动态可视化呈现各声道能量的空间分布。立体声声场为立体声仪，可按全频段、3 频段或 5 频段，以点、轮廓或填充方式显示。沉浸声声场使用轻量的二维房间视图，支持从 3.0 到 9.1.6 的声道布局。

立体声模式下提供按频段划分的相关性显示，辅助观察左右声道关系及合并为单声道时可能出现的抵消问题。

Mono 模式默认隐藏，可在设置中启用。

> “沉浸声”是本应用的多声道可视化模式，不代表 Dolby Atmos 编码、解码或认证功能。

### 输入与输出音频分析

支持 Core Audio 输入设备；在 macOS 14.2 或更高版本中，还可通过 Core Audio Process Tap 分析输出音频，即各个应用播放到该输出的声音，不会改变或延迟信号。

应用启动时会自动监测当前 macOS 默认输出设备，也可随时切换到其他音频源。

支持最高 9.1.6 的声道布局，并可将最多 64 个物理声道自定义映射至不同的扬声器角色。

### 外观与语言

- 支持跟随系统、浅色和深色外观，颜色主题会为所有控件着色。
- 支持普通窗口与全屏使用。
- 在系统支持时使用原生 Liquid Glass 控件。
- 支持英语、简体中文和韩语。
- 设置更改会即时预览；点按“应用”保留，或点按“还原”恢复。切换语言无需重启，菜单栏也会随之更新。

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 处理器 | Apple Silicon Mac |
| 系统 | macOS 13 或更高版本 |
| 输出音频捕获 | macOS 14.2 或更高版本 |
| 已测试系统 | macOS 27.0（26A428），MacBook Pro M1 Max |

系统部署目标不等于所有版本均已完成兼容性验证。其他 macOS 版本的实际运行情况仍待测试。

## 下载与安装

1. 前往 [Releases 页面](https://github.com/jinboz12/Auraliscope/releases)下载 DMG 文件。
2. 打开 DMG，将 Auraliscope 拖入“应用程序”文件夹。
3. 从“应用程序”文件夹启动应用。
4. 根据提示授予音频捕获权限，并选择要分析的音频源。

当前版本为 **1.1（build 51）**，使用 ad hoc 签名，尚未经过 Apple 公证。下载文件为 `Auraliscope.dmg`，其中的应用为 `Auraliscope.app`。

如果 macOS 阻止首次启动，请先确认安装包来自本项目官方 Releases 页面，然后前往 **系统设置 → 隐私与安全性**，选择 **“仍要打开”**。

## 权限与隐私

Auraliscope 只请求所选音频源需要的权限：

| 音频源 | 所需权限 |
| --- | --- |
| 输入设备 | 麦克风 |
| 输出音频 | 系统音频录制 |

系统权限的具体名称和显示方式可能随 macOS 版本而变化。

**音频仅在本机内存中进行实时分析，应用不会将捕获的音频保存为文件或上传。**

## 使用提示

- 开始分析前，请确认所选设备、声道布局与实际音频路由一致。
- 分析多声道音频时，请检查物理声道与扬声器角色的映射。
- 相关性读数可辅助判断立体声兼容性，建议结合实际单声道试听理解。
- 声场可视化反映输入信号中各声道的能量关系，不等同于对房间声学或实际扬声器声场的测量。

## 问题反馈

欢迎通过 [GitHub Issues](https://github.com/jinboz12/Auraliscope/issues) 提交问题或建议。

为便于复现，请尽量提供：

- Auraliscope 版本号与 build 编号；
- macOS 版本及 Mac 型号；
- 使用的音频设备，以及监测的是输入还是输出；
- 声道布局及相关路由设置；
- 复现步骤、预期行为与实际表现；
- 必要的截图或录屏。

“帮助 ▸ 显示诊断日志”可打开应用的日志文件夹（只记录事件，不含音频）。提交材料前，请检查其中是否包含不宜公开的信息。

## 许可与使用范围

Copyright © 2026 JINBOZ.

任何人均可免费下载、安装并运行 Auraliscope 应用，用于自己的工作或私人用途。依据 CC BY-NC-ND 4.0，你可以在遵守许可证条款的前提下，出于非商业目的分享本项目的未修改副本。

### 免责声明

本软件按“现状”提供，不作任何明示或默示担保。在适用法律允许的范围内，作者不对因使用本软件而产生的损失承担责任。Auraliscope 所包含的第三方组件及材料适用各自的许可证。

Auraliscope 的频谱图展示参考了 [AudioSpectrogram](https://github.com/lmshao/AudioSpectrogram) 中的 dB 图例及时间、频率标记设计思路。Auraliscope 的实时分析与渲染采用独立的 Swift、Accelerate 和 Metal 实现，未链接该项目的 Rust 库。

---

<a id="한국어"></a>

# Auraliscope (한국어)

[English](#auraliscope) · [中文](#中文) · **한국어**

**macOS용 실시간 오디오 분석 및 시각화 도구입니다.**

Auraliscope는 라우드니스, 레벨, 스펙트럼, 스펙트로그램, 파형, 사운드스테이지, 스테레오 상관도를 한 창에 모아, 듣는 동안 소리의 다이내믹, 주파수 분포, 공간 이미지를 함께 볼 수 있게 해 줍니다.

음악 제작, 믹싱, 오디오 후반 작업은 물론, Mac에서 재생되는 소리를 살펴보는 일상적인 용도에도 적합합니다.

[다운로드](https://github.com/jinboz12/Auraliscope/releases) · [릴리스 노트](https://github.com/jinboz12/Auraliscope/releases/tag/v1.1) · [문제 신고](https://github.com/jinboz12/Auraliscope/issues)

## 주요 기능

### 라우드니스와 다이내믹

LUFS, 라우드니스 레인지(LRA), 트루 피크, VU 미터를 하나의 요약에서 보여 주며, 직접 고른 납품 기준(스트리밍, EBU R128, ATSC A/85, Netflix 등)을 목표로 삼습니다. 주 측정값은 순간, 단기, 통합 라우드니스 중에서 고를 수 있습니다.

트루 피크가 0 dBTP를 넘으면 오버와 그 크기가 표시되어, 주의가 필요한 피크를 쉽게 찾을 수 있습니다.

### 채널 레벨

채널마다 피크와 RMS를 피크 홀드, 트루 피크 오버 경고와 함께 보여 주어 채널 간 레벨을 쉽게 비교할 수 있습니다. 빨간 클립 표시등을 클릭하면 유지된 오버 경고가 지워집니다.

### 스펙트럼, 스펙트로그램, 파형

- **스펙트로그램과 스펙트럼**은 하나의 로그 주파수 축과 피아노 건반을 함께 쓰며, 실시간 스펙트럼과 그 기록을 나란히 보여 줍니다. 건반에는 감지된 주요 음높이, 즉 함께 울리는 음이 표시됩니다. 설정에서 패널을 미러로 바꿔 스펙트럼을 왼쪽에 둘 수 있습니다.
- **채널별 파형**은 2초, 4초 또는 8초 동안의 진폭과 트랜지언트를 보여 줍니다.

### 사운드스테이지와 상관도

스테레오와 이머시브 보기에서 각 채널의 에너지가 공간에 어떻게 놓이는지 보여 줍니다. 스테레오 사운드스테이지는 스테레오미터로, 전체 대역, 3개 또는 5개 대역을 점, 윤곽선 또는 채운 도형으로 그릴 수 있습니다. 이머시브 사운드스테이지는 3.0부터 9.1.6까지의 레이아웃을 위한 가벼운 2D 룸 보기입니다.

스테레오에서는 상관도를 주파수 대역별로 보여 주어, 좌우 채널의 관계와 모노로 합쳤을 때 생길 수 있는 상쇄를 판단하는 데 도움을 줍니다.

모노 모드는 기본적으로 숨겨져 있으며, 설정에서 켤 수 있습니다.

> "이머시브"는 이 앱의 멀티채널 보기 이름이며, Dolby Atmos 인코딩, 디코딩 또는 인증 기능을 뜻하지 않습니다.

### 입력과 출력 분석

Core Audio 입력 장치를 읽습니다. macOS 14.2 이상에서는 Core Audio 프로세스 탭으로 출력도 분석할 수 있으며, 각 앱이 그 출력으로 재생하는 소리를 신호를 바꾸거나 지연시키지 않고 측정합니다.

실행 시 현재 macOS 기본 출력을 측정하며, 언제든 다른 소스를 고를 수 있습니다.

최대 9.1.6 레이아웃을 지원하며, 최대 64개의 물리 채널을 원하는 스피커 역할에 라우팅할 수 있습니다.

### 모양과 언어

- 시스템, 라이트, 다크 모양을 지원하며, 색상 테마가 모든 컨트롤에 적용됩니다.
- 창 모드와 전체 화면에서 모두 사용할 수 있습니다.
- 시스템이 지원하면 기본 Liquid Glass 컨트롤을 사용합니다.
- 영어, 중국어 간체, 한국어를 지원합니다.
- 설정 변경은 즉시 미리 보기로 반영됩니다. 적용을 누르면 유지되고, 되돌리기를 누르면 이전 설정으로 돌아갑니다. 언어를 바꿀 때 재시작할 필요가 없으며, 메뉴 막대도 함께 바뀝니다.

## 시스템 요구 사항

| 항목 | 요구 사항 |
| --- | --- |
| 프로세서 | Apple Silicon Mac |
| 시스템 | macOS 13 이상 |
| 출력 캡처 | macOS 14.2 이상 |
| 테스트 환경 | macOS 27.0(26A428), MacBook Pro M1 Max |

배포 대상 버전이 모든 버전의 호환성 검증을 뜻하지는 않습니다. 다른 macOS 버전은 아직 테스트가 필요합니다.

## 다운로드 및 설치

1. [Releases 페이지](https://github.com/jinboz12/Auraliscope/releases)에서 DMG 파일을 내려받습니다.
2. DMG를 열고 Auraliscope를 응용 프로그램 폴더로 드래그합니다.
3. 응용 프로그램 폴더에서 Auraliscope를 엽니다.
4. 요청이 뜨면 오디오 캡처 권한을 허용하고, 분석할 소스를 고릅니다.

현재 버전은 **1.1(build 51)**입니다. ad hoc 서명되었으며 Apple의 공증을 받지 않았습니다. 다운로드 파일은 `Auraliscope.dmg`이며, 그 안의 앱은 `Auraliscope.app`입니다.

macOS가 첫 실행을 막으면, 이 프로젝트의 Releases 페이지에서 받은 파일인지 확인한 뒤 **시스템 설정 → 개인정보 보호 및 보안**에서 **그래도 열기**를 선택하세요.

## 권한과 개인정보

Auraliscope는 선택한 소스에 필요한 권한만 요청합니다.

| 소스 | 권한 |
| --- | --- |
| 입력 장치 | 마이크 |
| 출력 오디오 | 시스템 오디오 녹음 |

권한의 정확한 이름은 macOS 버전에 따라 다를 수 있습니다.

**오디오는 Mac의 메모리에서 실시간으로만 분석됩니다. Auraliscope는 캡처한 오디오를 파일로 저장하거나 업로드하지 않습니다.**

## 사용 팁

- 분석을 시작하기 전에 장치, 채널 레이아웃, 라우팅이 실제 오디오 경로와 일치하는지 확인하세요.
- 멀티채널 오디오는 물리 채널이 스피커 역할에 어떻게 매핑되는지 확인하세요.
- 상관도는 스테레오 호환성 판단에 도움이 되며, 모노로 직접 들어 보며 확인하는 것이 좋습니다.
- 사운드스테이지는 신호 안에서 채널 간 에너지 관계를 보여 줄 뿐, 룸 음향이나 실제 스피커 배치를 측정한 것이 아닙니다.

## 피드백

문제나 제안은 [GitHub Issues](https://github.com/jinboz12/Auraliscope/issues)로 보내 주세요.

재현에 도움이 되도록 다음을 함께 알려 주세요.

- Auraliscope 버전과 빌드 번호
- macOS 버전과 Mac 모델
- 사용한 오디오 장치, 그리고 입력과 출력 중 무엇을 측정했는지
- 채널 레이아웃과 라우팅
- 재현 단계, 기대한 동작과 실제 동작
- 필요하면 스크린샷이나 화면 녹화

도움말 ▸ 진단 로그 보기에서 앱의 로그 폴더를 열 수 있습니다(이벤트만 기록하며 오디오는 없습니다). 자료를 올리기 전에 공개하면 안 되는 정보가 없는지 확인하세요.

## 라이선스와 사용 범위

Copyright © 2026 JINBOZ.

누구나 Auraliscope를 무료로 내려받아 설치하고, 자신의 작업이나 개인 용도로 실행할 수 있습니다. CC BY-NC-ND 4.0에 따라, 라이선스 조건을 지키는 한 비상업적 목적으로 이 프로젝트의 수정하지 않은 사본을 공유할 수 있습니다.

### 면책 조항

이 소프트웨어는 명시적이든 묵시적이든 어떠한 보증도 없이 "있는 그대로" 제공됩니다. 관련 법이 허용하는 범위에서, 작성자는 이 소프트웨어 사용으로 생긴 손실에 책임지지 않습니다. Auraliscope에 포함된 서드파티 구성 요소와 자료에는 각각의 라이선스가 적용됩니다.

Auraliscope 스펙트로그램의 dB 범례와 시간·주파수 표시는 [AudioSpectrogram](https://github.com/lmshao/AudioSpectrogram)의 디자인을 참고했습니다. Auraliscope의 실시간 분석과 렌더링은 Swift, Accelerate, Metal로 독자적으로 구현되었으며, 해당 프로젝트의 Rust 라이브러리를 링크하지 않습니다.
