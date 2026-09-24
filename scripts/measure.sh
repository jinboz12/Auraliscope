#!/bin/zsh
set -euo pipefail
meter_pid="${1:-$(pgrep -x Auraliscope | head -n 1 || true)}"
if [[ -z "$meter_pid" ]]; then
    echo "请先启动 Release 应用、允许麦克风，并选择正在输入音频的设备。" >&2
    exit 1
fi
echo "请保持窗口可见并持续输入音频；第一组 top 采样是累计值，应忽略。"
top -l 16 -s 2 -pid "$meter_pid" -stats pid,command,cpu,mem,threads | awk '$1 == "PID" || $2 == "Auraliscope" { print; fflush() }'
