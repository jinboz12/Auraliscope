# Auraliscope 2.0 使用与测试

正式名称为 Auraliscope，版本 2.0，构建 91；Bridge 插件版本为 2.0.91。

1. 退出 Auraliscope、LABS 和 DAW，运行 `Auraliscope 2.0 build 91.pkg`，选择应用及需要的 VST3/AU 格式。
2. 安装器更新 Applications 中的正式版及系统插件目录中的 Bridge；不会删除 LABS、项目或报告。
3. 重新扫描 DAW 插件，插入 Auraliscope Bridge，点击 Open Auraliscope。多个实例时在设置中选择来源。
4. 播放已知素材，检查电平、响度、频谱、声场及通道布局；测试暂停、恢复、重置、工程保存与重新打开。
5. 使用 ⌘E 导出 PDF，⇧⌘E 导出 CSV。报告中的 NOTE/CHECK 需要结合实际素材判断。

需要 Apple silicon、macOS 13 或更新版本。安装包未签署 Developer ID，也未经公证；核对下载来源后，
可在系统设置的“隐私与安全性”中选择“仍要打开”。管理员认证只在系统界面完成。

LABS 的设置与权限保持独立；正式版插件使用独立连接。若用户 Library 中有重复插件，请先确认位置，
再手动移除重复副本并重新扫描。Netflix 预设不测对白门控响度，不会给出对白合规 PASS。

[安装说明](../docs/INSTALLATION.md) · [构建 91 验证记录](../docs/2.0_BUILD91_VALIDATION.md)
