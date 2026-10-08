# Auraliscope LABS 1.3dev build 67 测试说明

本次从 build 66 的实验工作树继续，保留“插件完成分析、LABS 接收结果并绘制”的架构。

## 安装

1. 退出 LABS 和 DAW，运行 `Auraliscope LABS 1.3dev build 67.pkg`。可同时安装 App、VST3、AU。
2. App 安装至 `/Applications/Auraliscope LABS.app`，插件安装至 `/Library/Audio/Plug-Ins/` 对应目录。
3. 如果主目录 `~/Library/Audio/Plug-Ins/` 还存在早期同名插件，请先将旧副本移出插件目录，避免 DAW 选到旧版。
4. 在 DAW 重新扫描后插入 Auraliscope Bridge，点击插件的 Open Auraliscope LABS。

安装包未做 Developer ID 签名或公证，macOS 可能要求在“隐私与安全性”中允许打开；安装需要管理员授权。
App 为 Apple silicon，要求 macOS 13 或更新版本；两种插件包含 arm64 和 x86_64，但本次没有 Intel 实机验证。
本轮没有实际执行管理员安装；包内容、权限和内部代码签名由提取检查验证。

## build 67 的优化

单／双通道 K-weighting 使用两路双精度 SIMD 内核，避免计算六路空通道；多通道仍采用原有分组内核。
立体声分频输出使用固定 SIMD 下标，减少循环内的动态索引。测量精度、60 Hz 结果更新率、频谱和历史长度均保持原设置。
build 66 的起始过冲、暂停时 True Peak 重置等修复继续保留。

建议用相同工程对照 build 66 和 67，尤其关注多个 Bridge 同时工作时的 DAW CPU，而不是单次瞬间峰值。
每次更换版本后完全退出并重开 DAW，确保插件二进制被重新载入。

## 建议优先测试

- **播放中 Reset**：先持续播放，再多次 Reset。使用稳定正弦波时，True Peak 不应在重置后凭空增加约 1 dB。
- **停止/暂停后的 True Peak 清除**：出现过峰值后暂停测量或停止 DAW，点击 LABS 的 TRUE PEAK；插件的保持峰值应被清除，无需先恢复播放。Integrated LUFS 保留。
- **双向切换**：在 Settings → Audio 的 Source type 里切换 Audio devices / Host plugins，点 Apply，检查所选来源与显示一致。
- **多个 insert**：同时放置两个 Bridge，分别命名，逐个选择，确认 LABS 显示的就是选中轨道；多个待选 insert 不应被随机挑选。
- **生命周期**：关闭插件窗口、重开 LABS、保存并重开工程，观察重连与波形/频谱恢复；另试 44.1/48/96 kHz。
- **音频透明性**：插入/移除或 bypass 插件不应改变声音；本机自动测试逐块检查输出与输入相同。

## 这次算法改变的边界

滤波器在启动、Reset 或断流之后需要先取得真实历史。预热为 65 个输入样本（44.1 kHz 时约 1.47 ms），
期间 sample peak 仍正常统计；无法获得完整历史的边缘不估计 inter-sample peak。这样避免把测量开始之前的未知
波形当成数字静音，也意味着不能从没有记录到的历史重建起点的真实峰值。已有完整历史后的脉冲和高频插值仍保留。

离线 bounce 仍不参与实时计量。网络面板仍是发现预览。此次验证以本机测试宿主为主，不能替代 Logic、Cubase、
REAPER、Live 等 DAW 的实际工程兼容性测试；旧版 DAW 测试记录保留在 VALIDATION.md，不能当作 build 67 的结果。

详细数值、测试覆盖与限制见 VALIDATION.md。
