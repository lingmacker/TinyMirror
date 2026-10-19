#!/usr/bin/env python3
"""Replay normalized arrival constraints through a muted real system audio queue."""
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import time
import wave

from CheckAudioQueueContinuity import analyze, self_check


def prepare(root):
    spec = json.loads((root / 'Tests/Fixtures/ALACStartupArrivals.json').read_text())
    anchors = spec.pop('anchors')
    assert anchors[0] == [0, 0]
    assert all(b[0] > a[0] and b[1] >= a[1] for a, b in zip(anchors, anchors[1:]))
    arrivals = [0] * (anchors[-1][0] + 1)
    for (a, t0), (b, t1) in zip(anchors, anchors[1:]):
        for index in range(a, b + 1):
            arrivals[index] = round(t0 + (t1 - t0) * (index - a) / (b - a))
    assert all(b >= a for a, b in zip(arrivals, arrivals[1:]))
    assert all(arrivals[index] == timestamp for index, timestamp in anchors)
    spec['arrivalsNs'] = arrivals
    destination = root / '.build/audio-queue-replay'
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'arrival.json').write_text(json.dumps(spec) + '\n')
    # Integer-Hz stereo tone remains continuous across the one-second chunks.
    rate = spec['sampleRate']
    second = b''.join(struct.pack('<hh', int(4000 * math.sin(2 * math.pi * 440 * i / rate)),
                                  int(4000 * math.sin(2 * math.pi * 660 * i / rate))) for i in range(rate))
    with wave.open(str(destination / 'tone.wav'), 'wb') as audio:
        audio.setparams((2, 2, rate, 0, 'NONE', 'not compressed'))
        for _ in range(math.ceil(arrivals[-1] / 1e9) + 2):
            audio.writeframes(second)
    subprocess.run(['afconvert', str(destination / 'tone.wav'), str(destination / 'tone.caf'), '-f', 'caff', '-d', 'alac#352'], check=True)
    return destination


def run(executable, destination, iteration):
    prefix = destination / f'run-{iteration}'
    with prefix.with_suffix('.out').open('w') as out:
        process = subprocess.Popen([str(executable), str(destination / 'arrival.json'), str(destination / 'tone.caf'), 'default'], stdout=out, stderr=subprocess.STDOUT)
        try:
            code = process.wait(timeout=40)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise
    if code:
        raise RuntimeError(f'Input replay failed with exit {code}: {prefix.with_suffix(".out")}')
    time.sleep(0.5)
    with prefix.with_suffix('.core.log').open('w') as out:
        subprocess.run(['/usr/bin/log', 'show', '--last', '5m', '--style', 'compact', '--predicate',
                        f'processIdentifier == {process.pid} AND subsystem BEGINSWITH "com.apple.coremedia"', '--info', '--debug'],
                       stdout=out, stderr=subprocess.DEVNULL, check=True)
    result = analyze(prefix.with_suffix('.core.log').read_text(errors='replace'))
    result.update(pid=process.pid, input=prefix.with_suffix('.out').read_text().strip())
    prefix.with_suffix('.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)
    if result['skipped_packets'] or result['resyncs_over_1ms']:
        raise RuntimeError('Real AudioQueue output skipped samples despite continuous complete input')


if __name__ == '__main__':
    self_check()
    root = Path.cwd()
    destination = prepare(root)
    executable = Path(sys.argv[1]).resolve()
    try:
        for iteration in range(1, 4):
            run(executable, destination, iteration)
    except ValueError as error:
        print(f'UNVERIFIED: {error}', file=sys.stderr)
        sys.exit(2)
    print('PASS three muted real-output arrival replays: zero skipped samples; no app/discovery started')
