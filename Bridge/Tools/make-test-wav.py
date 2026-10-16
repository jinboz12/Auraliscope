#!/usr/bin/env python3
"""Writes the Bridge test signal as a 32-bit float WAV: channel c = 0.5/(c+1)·sin(2π·(997 + 502c)·n/fs), so
L = 0.5·sin(2π·997·n/fs) and R = 0.25·sin(2π·1499·n/fs) (−6.02 and −12.04 dBFS peaks), the same signal as HostHarness
instance 0.  make-test-wav.py <out.wav> [rate] [seconds] [channels (2)]"""
import math, struct, sys
path = sys.argv[1]
rate = int(sys.argv[2]) if len(sys.argv) > 2 else 48000
seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 30
channels = int(sys.argv[4]) if len(sys.argv) > 4 else 2
frames = int(rate * seconds)
data = bytearray()
frame = struct.Struct('<' + 'f' * channels)
for n in range(frames):
    data += frame.pack(*(0.5 / (c + 1) * math.sin(2 * math.pi * (997 + 502 * c) * n / rate) for c in range(channels)))
with open(path, 'wb') as f:
    f.write(b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVE')
    f.write(b'fmt ' + struct.pack('<IHHIIHH', 16, 3, channels, rate, rate * 4 * channels, 4 * channels, 32))
    f.write(b'data' + struct.pack('<I', len(data)) + data)
