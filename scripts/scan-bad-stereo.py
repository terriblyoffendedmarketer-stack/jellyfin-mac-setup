#!/usr/bin/env python3
# scan-bad-stereo.py — Find stereo files with poor dynamic range (high LRA)
# Scans first 2 minutes of each file for speed. Outputs a list of files
# that would benefit from compression/normalization.
#
# Usage:
#   python3 scripts/scan-bad-stereo.py "/Volumes/Backup Plus/All Movies"
#   python3 scripts/scan-bad-stereo.py "/Volumes/Backup Plus/TV"
#
# Requires: ffmpeg, ffprobe

import subprocess
import json
import sys
import re
from pathlib import Path

MEDIA_EXTENSIONS = {'.mkv', '.mp4', '.avi', '.m4v', '.mov', '.ts', '.wmv'}
LRA_THRESHOLD = 13.0  # above this = needs processing

def probe_audio(filepath):
    cmd = ['ffprobe', '-v', 'quiet', '-print_format', 'json', '-show_streams', str(filepath)]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        data = json.loads(r.stdout)
        for s in data.get('streams', []):
            if s.get('codec_type') == 'audio':
                title = s.get('tags', {}).get('title', '') or s.get('tags', {}).get('name', '')
                return {
                    'channels': s.get('channels', 0),
                    'index': s['index'],
                    'title': title,
                    'has_normalized': 'normalized' in title.lower()
                }
    except:
        pass
    return None

def measure_lra(filepath, stream_index):
    cmd = [
        'ffmpeg', '-hide_banner', '-t', '120',
        '-i', str(filepath),
        '-map', f'0:{stream_index}',
        '-af', 'ebur128=peak=true',
        '-f', 'null', '-'
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        matches = re.findall(r'LRA:\s*([\d.]+)\s*LU', r.stderr)
        if matches:
            return float(matches[-1])
    except:
        pass
    return None

def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('.')
    if not path.exists():
        print(f"Error: {path} does not exist")
        sys.exit(1)

    files = sorted(
        f for f in path.rglob('*')
        if f.suffix.lower() in MEDIA_EXTENSIONS
        and not f.name.startswith('._')
        and '.normalizing' not in f.name
        and 'Audio Tests' not in str(f)
    )

    print(f"Scanning {len(files)} files for stereo with bad dynamic range...")
    print(f"Threshold: LRA > {LRA_THRESHOLD} LU needs processing")
    print(f"{'='*60}")

    bad_files = []
    checked = 0
    skipped = 0

    for i, f in enumerate(files, 1):
        rel = f.relative_to(path) if str(f).startswith(str(path)) else f.name
        audio = probe_audio(f)

        if not audio:
            continue
        if audio['has_normalized']:
            skipped += 1
            continue
        if audio['channels'] > 2:
            continue  # surround — handled by main batch

        checked += 1
        lra = measure_lra(f, audio['index'])
        if lra is None:
            continue

        status = "BAD" if lra > LRA_THRESHOLD else "ok"
        if lra > LRA_THRESHOLD:
            bad_files.append((rel, lra))
            print(f"[{i}/{len(files)}] BAD  LRA={lra:5.1f}  {rel}")
        elif checked % 20 == 0:
            print(f"[{i}/{len(files)}] scanning... ({checked} checked, {len(bad_files)} bad so far)")

    print(f"\n{'='*60}")
    print(f"Checked: {checked} stereo files")
    print(f"Skipped: {skipped} (already normalized)")
    print(f"Bad LRA (>{LRA_THRESHOLD}): {len(bad_files)}")

    if bad_files:
        print(f"\nFiles needing processing:")
        bad_files.sort(key=lambda x: -x[1])
        for rel, lra in bad_files:
            print(f"  LRA={lra:5.1f}  {rel}")

        list_file = path / 'bad-stereo-files.txt'
        with open(list_file, 'w') as out:
            for rel, lra in bad_files:
                out.write(f"{path / rel}\n")
        print(f"\nFile list saved to: {list_file}")

if __name__ == '__main__':
    main()
