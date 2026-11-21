#!/usr/bin/env python3
"""Summarize a SightSense walk recording: how often it spoke, about what, and how fast.

Copy a recording off the phone (Finder → iPhone → Files → SightSense → Recordings, or the
Files app), then run:

    python3 Tools/summarize_walk.py path/to/Recordings/2026-11-21_14-03-10

To measure misses and false alarms, watch the frames in that folder alongside the event list
and note which alerts were right. No third-party packages needed.
"""
import json
import statistics
import sys
from collections import Counter
from pathlib import Path


def load(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def percentile(values: list[float], p: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * p))]


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    folder = Path(sys.argv[1])
    frames = load(folder / "frames.jsonl")
    events = load(folder / "events.jsonl")
    if not frames:
        sys.exit(f"No frames.jsonl in {folder}")

    minutes = max(frames[-1]["time"] - frames[0]["time"], 1) / 60
    print(f"Walk: {minutes:.1f} min, {len(frames)} frames ({len(frames) / minutes / 60:.1f} fps)")
    print(f"Alerts: {len(events)} ({len(events) / minutes:.1f} per minute), "
          f"{sum(e['urgent'] for e in events)} urgent")
    for kind, count in Counter(e["kind"] for e in events).most_common():
        print(f"  {kind:<12} {count:>4}  ({count / minutes:.1f}/min)")

    if events:
        end_to_end = [e["endToEndMs"] for e in events]
        pipeline = [e["pipelineMs"] for e in events]
        print(f"Latency, first seen → sound: median {statistics.median(end_to_end):.0f} ms, "
              f"95th percentile {percentile(end_to_end, 0.95):.0f} ms")
        print(f"Latency, frame → sound:      median {statistics.median(pipeline):.0f} ms, "
              f"95th percentile {percentile(pipeline, 0.95):.0f} ms")
        print("\nLast alerts (time in seconds from start):")
        for e in events[-20:]:
            print(f"  {e['time']:7.1f}s  {'URGENT ' if e['urgent'] else '       '}{e['text']}")


if __name__ == "__main__":
    main()
