"""Compares two directories of Float32 spectrogram dumps written by EnhancedNumerics (see enhanced-numerics.sh).

usage: compare-numerics.py <reference dir> <candidate dir>

Per signal: the absolute error in dB (maximum, mean, RMS), the largest difference's column and row (with the row's
approximate frequency), how many cells differ by more than 0.01, 0.1, 0.5 and 1 dB, and the relative error in power
where the reference is above the −120 dB floor. Written to stdout as plain text; nothing else is changed.
"""
import math
import os
import struct
import sys

ROWS = 512
FLOOR = -120.0


def read(path):
    data = open(path, "rb").read()
    count = len(data) // 4
    return struct.unpack("<%df" % count, data)


def row_frequency(row, upper=20_000.0):
    # LogFrequencyAxis.centre: lowest * (upper / lowest) ** ((row + 0.5) / rows), lowest = 20 Hz.
    return 20.0 * (upper / 20.0) ** ((row + 0.5) / ROWS)


def main():
    reference, candidate = sys.argv[1], sys.argv[2]
    names = sorted(n[:-4] for n in os.listdir(reference) if n.endswith(".f32") and not n.startswith("._"))
    print("%-8s %10s %10s %10s  %-12s %-14s %6s %6s %6s %6s  %s" % (
        "signal", "max dB", "mean dB", "rms dB", "worst col", "worst row", ">0.01", ">0.1", ">0.5", ">1", "max rel power (ref > -120 dB)"))
    for name in names:
        a = read(os.path.join(reference, name + ".f32"))
        b = read(os.path.join(candidate, name + ".f32"))
        if len(a) != len(b):
            print("%-8s length differs: %d and %d" % (name, len(a), len(b)))
            continue
        count = len(a)
        worst, worst_at = 0.0, 0
        total, squares = 0.0, 0.0
        over = {0.01: 0, 0.1: 0, 0.5: 0, 1.0: 0}
        relative = 0.0
        identical = 0
        for i, (x, y) in enumerate(zip(a, b)):
            d = abs(x - y)
            if d == 0:
                identical += 1
            total += d
            squares += d * d
            if d > worst:
                worst, worst_at = d, i
            for limit in over:
                if d > limit:
                    over[limit] += 1
            if x > FLOOR:
                # Relative error in power, where the reference is above the floor: |Pa - Pb| / Pa with P = 10^(dB / 10).
                pa, pb = 10 ** (x / 10), 10 ** (y / 10)
                relative = max(relative, abs(pa - pb) / pa)
        column, row = divmod(worst_at, ROWS)
        print("%-8s %10.6f %10.3e %10.3e  %-12d %4d (%7.1f Hz) %6d %6d %6d %6d  %.3e   identical %d of %d" % (
            name, worst, total / count, math.sqrt(squares / count), column, row, row_frequency(row),
            over[0.01], over[0.1], over[0.5], over[1.0], relative, identical, count))


if __name__ == "__main__":
    main()
