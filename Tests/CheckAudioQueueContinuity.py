#!/usr/bin/env python3
"""Hardware integration oracle: AudioQueue output must not skip continuous ALAC samples."""
import argparse
import json
from pathlib import Path
import re


def analyze(text):
    rows = []
    segments = []
    duration = 352 / 44100
    for line in text.splitlines():
        match = re.search(r"enqueueing #(\d+) from ([0-9.]+) to ([0-9.]+) \(duration: ([0-9.]+)", line)
        if not match:
            continue
        index, start, _, packet_duration = match.groups()
        if abs(float(packet_duration) - duration) > 0.000002:
            raise ValueError("Output packet duration differs from the 352-frame ALAC fixture")
        row = (int(index), float(start))
        if rows and row[0] <= rows[-1][0]:
            segments.append(rows)
            rows = []
        rows.append(row)
    if rows:
        segments.append(rows)
    if sum(map(len, segments)) < 10:
        raise ValueError("Insufficient AudioQueue output observations; this is not a passing check")
    skips = []
    for segment in segments:
        first_index, first_pts = segment[0]
        # Apple's text log rounds PTS to milliseconds; a packet is nearly 8 ms.
        drift = [round((pts - first_pts) / duration) - (index - first_index) for index, pts in segment]
        skips.append(max(drift) - min(drift))
    resyncs = re.findall(r"Resyncing AQ timeline - time diff is (\d+)/(\d+)", text)
    return {
        "output_observations": sum(map(len, segments)),
        "queue_segments": len(segments),
        "skipped_packets": sum(skips),
        "skipped_frames": sum(skips) * 352,
        "resyncs_over_1ms": sum(int(n) / int(d) > 0.001 for n, d in resyncs),
    }


def self_check():
    prefix = "subaq_enqueueAQBufferIntoAudioQueue: enqueueing "
    contiguous = "\n".join(f"{prefix}#{i + 1} from {1000 + i * 352 / 44100:.3f} to 0 (duration: 0.007982" for i in range(15))
    assert analyze(contiguous)["skipped_packets"] == 0
    missing = "\n".join(f"{prefix}#{i + 1} from {1000 + (i + (8 if i >= 5 else 0)) * 352 / 44100:.3f} to 0 (duration: 0.007982" for i in range(15))
    assert analyze(missing)["skipped_packets"] == 8
    try:
        analyze("")
    except ValueError:
        pass
    else:
        raise AssertionError("Missing observations must not pass")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    self_check()
    try:
        result = analyze(args.log.read_text(errors="replace"))
    except ValueError as error:
        parser.exit(2, f"UNVERIFIED: {error}\n")
    print(json.dumps(result, indent=2))
    if result["skipped_packets"] or result["resyncs_over_1ms"]:
        parser.exit(1, "FAIL: continuous ALAC input did not remain continuous in the real AudioQueue output\n")
    print("PASS real AudioQueue output is continuous")
