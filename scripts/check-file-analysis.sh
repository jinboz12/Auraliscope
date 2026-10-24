#!/bin/zsh
# Meter ▸ Analyze Audio File… against reference tones: EBU Tech 3341 case 1 (stereo 1 kHz at −23 dBFS reads
# −23.0 LUFS), the same tone on L alone (−26.0) and on Ls alone in a 5.1 file (+1.5 dB surround weight: −24.5),
# an AAC copy of case 1 decoded by Core Audio, and an unreadable file. Defaults to the debug build; override
# AURALISCOPE_BINARY to check the exact release/QA executable instead.
set -euo pipefail
cd "${0:A:h:h}"
binary="${AURALISCOPE_BINARY:-.build/debug/Auraliscope}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
import math, struct, sys, wave
def tone(path, channels, live, seconds=20, rate=48000, level=-23):
    a = 10 ** (level / 20)
    with wave.open(path, "wb") as w:
        w.setnchannels(channels); w.setsampwidth(2); w.setframerate(rate)
        frames = bytearray()
        for i in range(rate * seconds):
            v = int(round(a * math.sin(2 * math.pi * 1000 * i / rate) * 32767))
            frames += struct.pack("<" + "h" * channels, *[v if c in live else 0 for c in range(channels)])
        w.writeframes(bytes(frames))
tone(sys.argv[1] + "/stereo.wav", 2, {0, 1})
tone(sys.argv[1] + "/left.wav", 2, {0})
tone(sys.argv[1] + "/ls51.wav", 6, {4}, seconds=10)
open(sys.argv[1] + "/broken.mp3", "w").write("not audio")
PY
afconvert -f m4af -d aac -b 256000 "$work/stereo.wav" "$work/stereo.m4a"
failures=0
check() {
    local file="$1" expected="$2"
    local line
    line="$("$binary" --analyze-file "$work/$file" --analyze-report "$work/$file.pdf" -showWelcomeOnLaunch NO 2>/dev/null | grep '^analysis' || true)"
    if [[ "$line" == *"$expected"* && ( "$expected" == "failed"* || -s "$work/$file.pdf" ) ]]; then
        echo "ok   $file: $expected"
    else
        echo "FAIL $file: expected '$expected', got '$line'"; failures=$((failures + 1))
    fi
}
check stereo.wav "−23.0 LUFS"
check left.wav "−26.0 LUFS"
check ls51.wav "−24.5 LUFS"
check stereo.m4a "−23.0 LUFS"
check broken.mp3 "failed"
(( failures == 0 )) && echo "PASS: file analysis" || { echo "$failures failure(s)"; exit 1; }
