#!/usr/bin/env python3
"""Paired VST3 process CPU comparison, with the same HostHarness and private socket.

Run from the worktree root. Both arguments are existing VST3 bundles. Each pair
alternates order; report medians and raw observations, never a single best run.
Audio stays inside HostHarness. Every run must pass its bitwise passthrough check.
"""
import argparse
import json
import os
from pathlib import Path
import resource
import statistics
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('baseline', type=Path)
parser.add_argument('candidate', type=Path)
parser.add_argument('--seconds', type=int, default=15)
parser.add_argument('--pairs', type=int, default=3)
args = parser.parse_args()
if args.seconds < 1 or args.pairs < 1:
    parser.error('seconds and pairs must be positive')
root = Path(__file__).resolve().parents[2]
host = root / '.build/bridge/tools/HostHarness'
for path in (host, args.baseline, args.candidate):
    if not path.exists():
        parser.error(f'missing: {path}')
cases = [('8x-mono-48k', 8, 1, 48000, 256),
         ('32x-stereo-48k', 32, 2, 48000, 256),
         ('8x-stereo-96k', 8, 2, 96000, 512),
         ('8x-stereo-192k', 8, 2, 192000, 1024)]
rows = []
with tempfile.TemporaryDirectory(prefix='abr-perf-') as directory:
    env = dict(os.environ, AURALISCOPE_BRIDGE_SOCKET=directory + '/bridge.sock')
    for name, instances, channels, rate, block in cases:
        for pair in range(args.pairs):
            for which in ([0, 1] if pair % 2 == 0 else [1, 0]):
                bundle = (args.baseline, args.candidate)[which].resolve()
                command = [str(host), '--format', 'vst3', '--bundle', str(bundle),
                           '--instances', str(instances), '--channels', str(channels),
                           '--rate', str(rate), '--block', str(block), '--phases', f'live:{args.seconds}']
                before = resource.getrusage(resource.RUSAGE_CHILDREN)
                result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, timeout=args.seconds + 60)
                after = resource.getrusage(resource.RUSAGE_CHILDREN)
                if result.returncode or 'PASS: 0 output mismatch(es), 0 process error(s)' not in result.stdout:
                    raise RuntimeError(result.stdout)
                cpu = 100 * (after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime) / args.seconds
                row = dict(case=name, pair=pair + 1, build=('baseline', 'candidate')[which], cpu=cpu)
                rows.append(row)
                print(json.dumps(row), flush=True)
for name, *_ in cases:
    medians = {build: statistics.median(r['cpu'] for r in rows if r['case'] == name and r['build'] == build)
               for build in ('baseline', 'candidate')}
    change = 100 * (medians['candidate'] / medians['baseline'] - 1)
    print(json.dumps(dict(case=name, medians=medians, relative_percent=change)), flush=True)
