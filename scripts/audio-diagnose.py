#!/usr/bin/env python3
# audio-diagnose.py — Measure audio quality metrics for before/after comparison
#
# Analyzes each audio track in a media file and reports:
#   - Integrated loudness (LUFS) — overall volume level
#   - Loudness Range (LRA) — how wide the gap is between quiet and loud parts
#     (lower = more compressed = better for home speakers)
#   - True Peak (dBTP) — loudest moment
#   - Dynamic spread = Peak - Integrated — practical "explosion vs dialogue" gap
#   - Dialogue frequency energy (1-4kHz band where speech lives)
#
# A good normalized track should have:
#   - LRA around 7-11 (original surround is often 15-25)
#   - Integrated loudness around -16 LUFS
#   - Dynamic spread under 15 dB (original can be 20-30+)
#
# Usage:
#   python3 scripts/audio-diagnose.py /path/to/movie.mp4
#   python3 scripts/audio-diagnose.py /path/to/movie.mp4 --scene 01:30:00-01:32:00
#   python3 scripts/audio-diagnose.py /path/to/movie.mp4 --compare
#
# Requires: ffmpeg, ffprobe

import subprocess
import json
import sys
import re
import argparse
from pathlib import Path


def probe_audio_streams(filepath):
    cmd = [
        'ffprobe', '-v', 'quiet', '-print_format', 'json',
        '-show_streams', '-show_format', str(filepath)
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        print(f"Error probing file: {result.stderr[:200]}")
        sys.exit(1)
    data = json.loads(result.stdout)
    streams = []
    for s in data.get('streams', []):
        if s.get('codec_type') == 'audio':
            title = s.get('tags', {}).get('title', '') or s.get('tags', {}).get('name', '')
            streams.append({
                'index': s['index'],
                'codec': s.get('codec_name', '?'),
                'channels': s.get('channels', 0),
                'channel_layout': s.get('channel_layout', ''),
                'title': title,
                'sample_rate': s.get('sample_rate', ''),
            })
    duration = float(data.get('format', {}).get('duration', 0))
    return streams, duration


def measure_loudness(filepath, stream_index, start=None, duration_sec=None):
    """Run ebur128 loudness scan on a specific audio stream."""
    cmd = ['ffmpeg', '-hide_banner']

    if start:
        cmd.extend(['-ss', start])
    if duration_sec:
        cmd.extend(['-t', str(duration_sec)])

    cmd.extend([
        '-i', str(filepath),
        '-map', f'0:{stream_index}',
        '-af', 'ebur128=peak=true',
        '-f', 'null', '-'
    ])

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    stderr = result.stderr

    # Parse ebur128 SUMMARY from stderr (use last match — first matches are per-frame)
    metrics = {}

    matches = re.findall(r'I:\s*([-\d.]+)\s*LUFS', stderr)
    if matches:
        metrics['integrated_lufs'] = float(matches[-1])

    matches = re.findall(r'LRA:\s*([-\d.]+)\s*LU', stderr)
    if matches:
        metrics['lra'] = float(matches[-1])

    matches = re.findall(r'Peak:\s*([-\d.]+)\s*dBFS', stderr)
    if matches:
        metrics['true_peak'] = float(matches[-1])

    if 'integrated_lufs' in metrics and 'true_peak' in metrics:
        metrics['dynamic_spread'] = metrics['true_peak'] - metrics['integrated_lufs']

    return metrics


def measure_dialogue_energy(filepath, stream_index, start=None, duration_sec=None):
    """Measure energy in the dialogue frequency band (1-4kHz) vs full spectrum."""
    cmd_full = ['ffmpeg', '-hide_banner']
    cmd_band = ['ffmpeg', '-hide_banner']

    if start:
        cmd_full.extend(['-ss', start])
        cmd_band.extend(['-ss', start])
    if duration_sec:
        cmd_full.extend(['-t', str(duration_sec)])
        cmd_band.extend(['-t', str(duration_sec)])

    # Full spectrum RMS
    cmd_full.extend([
        '-i', str(filepath),
        '-map', f'0:{stream_index}',
        '-af', 'astats=metadata=1:reset=0,ametadata=print:key=lavfi.astats.Overall.RMS_level',
        '-f', 'null', '-'
    ])

    # Dialogue band (1-4kHz) RMS
    cmd_band.extend([
        '-i', str(filepath),
        '-map', f'0:{stream_index}',
        '-af', 'highpass=f=1000,lowpass=f=4000,astats=metadata=1:reset=0,ametadata=print:key=lavfi.astats.Overall.RMS_level',
        '-f', 'null', '-'
    ])

    result_full = subprocess.run(cmd_full, capture_output=True, text=True, timeout=600)
    result_band = subprocess.run(cmd_band, capture_output=True, text=True, timeout=600)

    metrics = {}

    # Get the last RMS values (overall average)
    rms_values = re.findall(r'lavfi\.astats\.Overall\.RMS_level=([-\d.]+)', result_full.stderr)
    if rms_values:
        metrics['full_rms_db'] = float(rms_values[-1])

    rms_values = re.findall(r'lavfi\.astats\.Overall\.RMS_level=([-\d.]+)', result_band.stderr)
    if rms_values:
        metrics['dialogue_band_rms_db'] = float(rms_values[-1])

    if 'full_rms_db' in metrics and 'dialogue_band_rms_db' in metrics:
        metrics['dialogue_prominence'] = metrics['dialogue_band_rms_db'] - metrics['full_rms_db']

    return metrics


def format_metric(value, unit, good_range=None):
    """Format a metric with a quality indicator."""
    text = f"{value:+.1f} {unit}" if value >= 0 else f"{value:.1f} {unit}"
    if good_range:
        lo, hi = good_range
        if lo <= value <= hi:
            text += "  [GOOD]"
        elif value < lo:
            text += "  [too low]"
        else:
            text += "  [too high]"
    return text


def analyze_track(filepath, stream, label, start=None, duration_sec=None):
    """Full analysis of one audio track."""
    print(f"\n  --- {label} ---")
    print(f"  Codec: {stream['codec']} | Channels: {stream['channels']} ({stream['channel_layout']})")

    print(f"  Scanning loudness... ", end='', flush=True)
    loudness = measure_loudness(filepath, stream['index'], start, duration_sec)
    print("done")

    if not loudness:
        print("  ERROR: Could not measure loudness")
        return None

    results = {**loudness}

    if 'integrated_lufs' in loudness:
        print(f"  Integrated Loudness: {format_metric(loudness['integrated_lufs'], 'LUFS', (-18, -14))}")
    if 'lra' in loudness:
        print(f"  Loudness Range (LRA): {format_metric(loudness['lra'], 'LU', (7, 13))}")
        print(f"    ^ This is the key number. Lower = less gap between dialogue and explosions.")
    if 'true_peak' in loudness:
        print(f"  True Peak: {format_metric(loudness['true_peak'], 'dBFS', (-3, 0))}")
    if 'dynamic_spread' in loudness:
        print(f"  Dynamic Spread: {format_metric(loudness['dynamic_spread'], 'dB', (10, 18))}")
        print(f"    ^ Peak-to-average gap. Lower = more even volume.")

    return results


def compare_tracks(original, normalized):
    """Print a comparison between original and normalized metrics."""
    print("\n  === COMPARISON ===")

    if 'lra' in original and 'lra' in normalized:
        diff = original['lra'] - normalized['lra']
        print(f"  LRA reduction:      {diff:+.1f} LU  (original {original['lra']:.1f} -> normalized {normalized['lra']:.1f})")
        if diff > 3:
            print(f"    Dynamic range compressed by {diff:.0f} LU — should sound noticeably more even")
        elif diff > 0:
            print(f"    Slight compression — may be subtle")
        else:
            print(f"    No compression improvement — something may be off")

    if 'dynamic_spread' in original and 'dynamic_spread' in normalized:
        diff = original['dynamic_spread'] - normalized['dynamic_spread']
        print(f"  Spread reduction:   {diff:+.1f} dB  (original {original['dynamic_spread']:.1f} -> normalized {normalized['dynamic_spread']:.1f})")

    if 'integrated_lufs' in original and 'integrated_lufs' in normalized:
        diff = normalized['integrated_lufs'] - original['integrated_lufs']
        print(f"  Volume change:      {diff:+.1f} LUFS (original {original['integrated_lufs']:.1f} -> normalized {normalized['integrated_lufs']:.1f})")


def main():
    parser = argparse.ArgumentParser(description='Diagnose audio quality in media files')
    parser.add_argument('path', help='Media file to analyze')
    parser.add_argument('--scene', help='Time range to analyze (e.g. 00:05:00-00:07:00)', default=None)
    parser.add_argument('--compare', action='store_true',
                        help='Compare original vs normalized track (requires both to exist)')
    parser.add_argument('--quick', action='store_true',
                        help='Analyze first 2 minutes only (faster)')
    args = parser.parse_args()

    filepath = Path(args.path)
    if not filepath.exists():
        print(f"Error: {filepath} does not exist")
        sys.exit(1)

    print(f"File: {filepath.name}")
    print(f"{'='*60}")

    streams, duration = probe_audio_streams(filepath)
    if not streams:
        print("No audio streams found")
        sys.exit(1)

    print(f"Duration: {duration/60:.0f} min | Audio tracks: {len(streams)}")

    # Parse scene range
    start = None
    duration_sec = None
    if args.scene:
        parts = args.scene.split('-')
        start = parts[0]
        if len(parts) > 1:
            # Convert end time to duration
            def to_sec(t):
                p = t.split(':')
                return int(p[0])*3600 + int(p[1])*60 + float(p[2]) if len(p)==3 else int(p[0])*60 + float(p[1])
            duration_sec = to_sec(parts[1]) - to_sec(parts[0])
        print(f"Analyzing scene: {start}" + (f" ({duration_sec:.0f}s)" if duration_sec else ""))
    elif args.quick:
        duration_sec = 120
        print("Quick mode: analyzing first 2 minutes")

    # Find original and normalized tracks
    original = None
    normalized = None
    for s in streams:
        if 'normalized' in s['title'].lower():
            normalized = s
        elif original is None:
            original = s

    results = {}

    if args.compare and normalized:
        print("\n  Analyzing ORIGINAL track...")
        orig_metrics = analyze_track(filepath, original, f"Track {original['index']}: ORIGINAL ({original['title'] or 'untitled'})", start, duration_sec)

        print("\n  Analyzing NORMALIZED track...")
        norm_metrics = analyze_track(filepath, normalized, f"Track {normalized['index']}: NORMALIZED ({normalized['title']})", start, duration_sec)

        if orig_metrics and norm_metrics:
            compare_tracks(orig_metrics, norm_metrics)
    else:
        for s in streams:
            label = f"Track {s['index']}: {s['title'] or 'untitled'}"
            analyze_track(filepath, s, label, start, duration_sec)

    print(f"\n{'='*60}")
    print("WHAT THE NUMBERS MEAN:")
    print("  LRA (Loudness Range): The gap between quiet and loud parts")
    print("    Cinema/theatrical: 15-25 LU (huge gap — dialogue vanishes)")
    print("    Good for home:     7-11 LU  (even volume, clear dialogue)")
    print("    Over-compressed:   <5 LU    (sounds flat/lifeless)")
    print("")
    print("  Integrated Loudness: Overall volume level")
    print("    Our target: -16 LUFS (standard for streaming)")
    print("")
    print("  Dynamic Spread: Peak minus average")
    print("    >20 dB = explosions will blow your ears while dialogue whispers")
    print("    10-15 dB = comfortable for home viewing")


if __name__ == '__main__':
    main()
