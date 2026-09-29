#!/usr/bin/env python3
"""Writes the Bridge test signal as a 32-bit float WAV: L = 0.5·sin(2π·997·n/fs), R = 0.25·sin(2π·1499·n/fs)
(−6.02 and −12.04 dBFS peaks), the same signal as HostHarness instance 0.  make-test-wav.py <out.wav> [rate] [seconds]"""
import math, struct, sys
path = sys.argv[1]
rate = int(sys.argv[2]) if len(sys.argv) > 2 else 48000
seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 30
frames = int(rate * seconds)
data = bytearray()
for n in range(frames):
    data += struct.pack('<ff', 0.5 * math.sin(2 * math.pi * 997 * n / rate), 0.25 * math.sin(2 * math.pi * 1499 * n / rate))
with open(path, 'wb') as f:
    f.write(b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVE')
    f.write(b'fmt ' + struct.pack('<IHHIIHH', 16, 3, 2, rate, rate * 8, 8, 32))
    f.write(b'data' + struct.pack('<I', len(data)) + data)
