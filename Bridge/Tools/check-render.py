#!/usr/bin/env python3
"""Compares a rendered WAV (16/24-bit PCM or 32-bit float, stereo) with the Bridge test signal: the plugin passes
audio unchanged, so the render must equal the source within the file's quantization step."""
import math, struct, sys
data_bytes = open(sys.argv[1], 'rb').read()
pos, fmt, data = 12, None, b''
while pos < len(data_bytes):
    cid, size = data_bytes[pos:pos + 4], struct.unpack('<I', data_bytes[pos + 4:pos + 8])[0]
    body = data_bytes[pos + 8:pos + 8 + size]
    if cid == b'fmt ': fmt = struct.unpack('<HHIIHH', body[:16])
    if cid == b'data': data = body; break
    pos += 8 + size + (size & 1)
tag, channels, rate, _, align, bits = fmt
frames = min(len(data) // align, rate * 30)  # the looped 30 s source, first pass
step = 0 if tag == 3 else 2.0 ** -(bits - 1)
def sample(i, c):
    o = i * align + c * bits // 8
    if tag == 3: return struct.unpack('<f', data[o:o + 4])[0]
    return int.from_bytes(data[o:o + bits // 8], 'little', signed=True) * step
worst, peak = 0.0, [0.0, 0.0]
for i in range(frames):
    for c in range(2):
        s = sample(i, c)
        peak[c] = max(peak[c], abs(s))
        expected = 0.5 * math.sin(2 * math.pi * 997 * i / rate) if c == 0 else 0.25 * math.sin(2 * math.pi * 1499 * i / rate)
        worst = max(worst, abs(s - expected))
ok = rate == 48000 and worst <= max(step, 1e-7) * 1.01
print(f"render {rate} Hz {bits}-bit: peak L {20 * math.log10(peak[0]):.3f} R {20 * math.log10(peak[1]):.3f} dBFS, "
      f"largest deviation from the source {worst:.2e} (quantization step {step:.1e}): {'PASS' if ok else 'FAIL'}")
sys.exit(0 if ok else 1)
