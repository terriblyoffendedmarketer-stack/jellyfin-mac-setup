#!/usr/bin/env python3
# normalize-audio.py — Add normalized stereo audio track to media files
# for better dialogue clarity on home speakers/headphones/TV.
#
# Adds a "Normalized Stereo" track with centre-channel boost (for surround)
# and dynamic range compression. Original audio is preserved untouched.
#
# Usage:
#   python3 scripts/normalize-audio.py /Volumes/Backup\ Plus/All\ Movies
#   python3 scripts/normalize-audio.py /Volumes/Backup\ Plus/TV
#   python3 scripts/normalize-audio.py /path/to/single/file.mkv
#   python3 scripts/normalize-audio.py /path --dry-run          # preview only
#   python3 scripts/normalize-audio.py /path --limit 10         # process 10 files
#   python3 scripts/normalize-audio.py /path --skip-stereo      # skip already-stereo files
#
# Requires: ffmpeg, ffprobe (brew install ffmpeg)
#
# Gotchas:
# - ExFAT has no journaling — we write to a temp file in the same dir,
#   verify it, then rename. If the script is killed mid-write, the .tmp
#   file is leftover but the original is untouched.
# - loudnorm single-pass is slightly less accurate but the compressor
#   upstream does the heavy lifting anyway.
# - Some MKVs have PGS subtitles that can't go in MP4 containers.
#   If ffmpeg fails, we retry without subtitle streams.
# - Processing time: ~30-90 seconds per 1.5GB file (video is stream-copied,
#   only audio is encoded). ~650 files at 1TB ≈ 10-12 hours unattended.

import subprocess
import json
import sys
import os
import re
import shutil
import time
import argparse
import signal
from pathlib import Path
from datetime import datetime

MEDIA_EXTENSIONS = {'.mkv', '.mp4', '.avi', '.m4v', '.mov', '.ts', '.wmv'}
NORMALIZED_TITLE = "Normalized Stereo"
TEMP_INFIX = ".normalizing"

# --- Filter chains ---
# 5.1 surround: boost centre channel (dialogue), reduce LFE (explosions)
SURROUND_51_FILTER = (
    "pan=stereo|"
    "FL=1.0*FC+0.707*FL+0.5*BL+0.25*LFE|"
    "FR=1.0*FC+0.707*FR+0.5*BR+0.25*LFE,"
    "acompressor=threshold=0.089:ratio=4:attack=5:release=100:makeup=5:knee=6,"
    "loudnorm=I=-16:TP=-1.5:LRA=11"
)

# 7.1 surround: same idea, include side channels
SURROUND_71_FILTER = (
    "pan=stereo|"
    "FL=1.0*FC+0.707*FL+0.5*BL+0.5*SL+0.25*LFE|"
    "FR=1.0*FC+0.707*FR+0.5*BR+0.5*SR+0.25*LFE,"
    "acompressor=threshold=0.089:ratio=4:attack=5:release=100:makeup=5:knee=6,"
    "loudnorm=I=-16:TP=-1.5:LRA=11"
)

# Fallback surround (non-standard layout): let ffmpeg downmix, then compress
FALLBACK_SURROUND_FILTER = (
    "acompressor=threshold=0.089:ratio=4:attack=5:release=100:makeup=5:knee=6,"
    "loudnorm=I=-16:TP=-1.5:LRA=11"
)

# Stereo/mono: just compress and normalize
STEREO_FILTER = (
    "acompressor=threshold=0.089:ratio=4:attack=5:release=100:makeup=5:knee=6,"
    "loudnorm=I=-16:TP=-1.5:LRA=11"
)

shutdown_requested = False

def handle_signal(sig, frame):
    global shutdown_requested
    shutdown_requested = True
    print("\nShutdown requested — finishing current file then stopping...")

signal.signal(signal.SIGINT, handle_signal)
signal.signal(signal.SIGTERM, handle_signal)


def probe_file(filepath):
    cmd = [
        'ffprobe', '-v', 'quiet',
        '-print_format', 'json',
        '-show_streams', '-show_format',
        str(filepath)
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            return None
        return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        return None


def get_audio_streams(probe_data):
    if not probe_data or 'streams' not in probe_data:
        return []
    return [
        {
            'index': s['index'],
            'codec': s.get('codec_name', 'unknown'),
            'channels': s.get('channels', 0),
            'channel_layout': s.get('channel_layout', ''),
            'title': s.get('tags', {}).get('title', '') or s.get('tags', {}).get('name', ''),
            'language': s.get('tags', {}).get('language', 'und'),
        }
        for s in probe_data['streams']
        if s.get('codec_type') == 'audio'
    ]


def has_normalized_track(audio_streams):
    return any(NORMALIZED_TITLE.lower() in s['title'].lower() for s in audio_streams)


def pick_filter(channels, channel_layout):
    if channels >= 8 or '7.1' in channel_layout:
        return SURROUND_71_FILTER, "7.1→stereo", True
    elif channels >= 6 or '5.1' in channel_layout:
        return SURROUND_51_FILTER, "5.1→stereo", True
    elif channels > 2:
        return FALLBACK_SURROUND_FILTER, f"{channels}ch→stereo", True
    else:
        return STEREO_FILTER, f"{channels}ch stereo", False


LRA_THRESHOLD = 13.0  # stereo files with LRA below this are fine, skip them


def measure_lra(filepath, stream_index):
    """Measure LRA by scanning the FULL audio track (no sampling).
    Only decodes audio, not video — takes ~30-60s per file."""
    cmd = [
        'ffmpeg', '-hide_banner', '-loglevel', 'error',
        '-i', str(filepath),
        '-map', f'0:{stream_index}',
        '-af', 'ebur128=peak=true',
        '-f', 'null', '-'
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        matches = re.findall(r'LRA:\s*([\d.]+)\s*LU', result.stderr)
        if matches:
            return float(matches[-1])
    except subprocess.TimeoutExpired:
        pass
    return None


def run_ffmpeg(cmd, timeout=1800):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None


def process_file(filepath, dry_run=False, skip_stereo=False, lra_check=False):
    filepath = Path(filepath)

    probe_data = probe_file(filepath)
    if not probe_data:
        return 'error', "Could not probe file"

    audio_streams = get_audio_streams(probe_data)
    if not audio_streams:
        return 'skip', "No audio streams"

    if has_normalized_track(audio_streams):
        return 'skip', "Already normalized"

    source = audio_streams[0]
    channels = source['channels']
    layout = source['channel_layout']
    lang = source['language']

    audio_filter, source_desc, is_surround = pick_filter(channels, layout)

    if skip_stereo and not is_surround:
        return 'skip', f"Stereo source (--skip-stereo)"

    duration = float(probe_data.get('format', {}).get('duration', 0))

    # For stereo files with --lra-check: scan full audio, skip if LRA is fine
    if lra_check and not is_surround:
        lra = measure_lra(filepath, source['index'])
        if lra is not None and lra <= LRA_THRESHOLD:
            return 'skip', f"Stereo LRA OK ({lra:.1f} <= {LRA_THRESHOLD})"
        if lra is not None:
            source_desc = f"{source_desc} LRA={lra:.1f}"
        elif lra is None:
            source_desc = f"{source_desc} LRA=unknown"

    if dry_run:
        return 'would_process', f"{source_desc} | {duration/60:.0f}min"

    new_idx = len(audio_streams)
    temp_path = filepath.parent / (filepath.stem + TEMP_INFIX + filepath.suffix)

    # Build command using filter_complex
    base_cmd = [
        'ffmpeg', '-y', '-hide_banner', '-loglevel', 'warning',
        '-i', str(filepath),
        '-filter_complex', f'[0:a:0]{audio_filter}[norm]',
        '-map', '0',
        '-map', '[norm]',
        '-c', 'copy',
        f'-c:a:{new_idx}', 'aac',
        f'-b:a:{new_idx}', '192k',
        f'-metadata:s:a:{new_idx}', f'title={NORMALIZED_TITLE}',
        f'-metadata:s:a:{new_idx}', f'language={lang}',
        f'-disposition:a:{new_idx}', '0',
    ]

    # For surround with pan filter, force stereo output on the new track
    if is_surround and 'pan=stereo' not in audio_filter:
        base_cmd.extend([f'-ac:a:{new_idx}', '2'])

    base_cmd.append(str(temp_path))

    start = time.time()
    result = run_ffmpeg(base_cmd)

    # If failed, try fallback strategies
    if result is None or result.returncode != 0:
        stderr = (result.stderr if result else "timeout")[-300:]

        # Strategy 1: if pan filter failed, retry with fallback (auto downmix)
        if is_surround and 'pan=' in audio_filter:
            fallback_cmd = list(base_cmd)
            fc_idx = fallback_cmd.index('-filter_complex') + 1
            fallback_cmd[fc_idx] = f'[0:a:0]{FALLBACK_SURROUND_FILTER}[norm]'
            fallback_cmd.insert(fallback_cmd.index(str(temp_path)), '2')
            fallback_cmd.insert(fallback_cmd.index('2'), f'-ac:a:{new_idx}')
            result = run_ffmpeg(fallback_cmd)

        # Strategy 2: skip subtitles (common issue with PGS in MP4)
        if result is None or result.returncode != 0:
            nosub_cmd = [
                'ffmpeg', '-y', '-hide_banner', '-loglevel', 'warning',
                '-i', str(filepath),
                '-filter_complex', f'[0:a:0]{audio_filter}[norm]',
                '-map', '0:v', '-map', '0:a', '-map', '[norm]',
                '-c', 'copy',
                f'-c:a:{new_idx}', 'aac',
                f'-b:a:{new_idx}', '192k',
                f'-metadata:s:a:{new_idx}', f'title={NORMALIZED_TITLE}',
                f'-metadata:s:a:{new_idx}', f'language={lang}',
                f'-disposition:a:{new_idx}', '0',
                str(temp_path)
            ]
            result = run_ffmpeg(nosub_cmd)

        if result is None or result.returncode != 0:
            if temp_path.exists():
                temp_path.unlink()
            stderr = (result.stderr if result else "timeout")[-200:]
            return 'error', f"FFmpeg failed: {stderr}"

    elapsed = time.time() - start

    # Verify output
    if not temp_path.exists():
        return 'error', "Output file not created"

    temp_size = temp_path.stat().st_size
    orig_size = filepath.stat().st_size

    if temp_size < orig_size * 0.5:
        temp_path.unlink()
        return 'error', f"Output suspiciously small ({temp_size/1e6:.0f}MB vs {orig_size/1e6:.0f}MB)"

    out_probe = probe_file(temp_path)
    out_audio = get_audio_streams(out_probe)
    if not has_normalized_track(out_audio):
        temp_path.unlink()
        return 'error', "Normalized track missing from output"

    # Replace original (clear uchg flag if macOS locked the file after dirty USB eject)
    try:
        temp_path.replace(filepath)
    except (OSError, PermissionError):
        try:
            subprocess.run(['chflags', 'nouchg', str(filepath)], timeout=5)
            temp_path.replace(filepath)
        except (OSError, PermissionError):
            try:
                shutil.copy2(str(temp_path), str(filepath))
                temp_path.unlink()
            except (OSError, PermissionError) as e:
                if temp_path.exists():
                    temp_path.unlink()
                return 'error', f"Permission denied replacing file: {e}"

    added_mb = (temp_size - orig_size) / (1024 * 1024)
    return 'done', f"{source_desc} | +{added_mb:.1f}MB | {elapsed:.0f}s"


def scan_media(path):
    path = Path(path)
    if path.is_file():
        return [path] if path.suffix.lower() in MEDIA_EXTENSIONS else []

    files = []
    for f in sorted(path.rglob('*')):
        if f.suffix.lower() in MEDIA_EXTENSIONS and TEMP_INFIX not in f.name and not f.name.startswith('._'):
            files.append(f)
    return files


def cleanup_temp_files(path):
    path = Path(path)
    if path.is_file():
        return
    count = 0
    for f in path.rglob(f'*{TEMP_INFIX}*'):
        try:
            if not f.name.startswith('._'):
                f.unlink()
                count += 1
        except OSError:
            pass
    if count:
        print(f"Cleaned up {count} leftover temp file(s) from previous run")


def main():
    parser = argparse.ArgumentParser(
        description='Add normalized stereo audio track to media files'
    )
    parser.add_argument('path', help='Media file or directory to process')
    parser.add_argument('--dry-run', action='store_true',
                        help='Preview what would be processed')
    parser.add_argument('--limit', type=int, default=0,
                        help='Process at most N files (0 = unlimited)')
    parser.add_argument('--skip-stereo', action='store_true',
                        help='Skip files that already have stereo audio')
    parser.add_argument('--lra-check', action='store_true',
                        help='For stereo files: scan full audio and skip if LRA <= 13 (already OK)')
    args = parser.parse_args()

    target = Path(args.path)
    if not target.exists():
        print(f"Error: {target} does not exist")
        sys.exit(1)

    # Clean up temp files from interrupted runs
    cleanup_temp_files(target)

    print(f"Scanning: {target}")
    files = scan_media(target)
    print(f"Found {len(files)} media files\n")

    if not files:
        sys.exit(0)

    stats = {'done': 0, 'skip': 0, 'error': 0, 'would_process': 0}
    log_dir = target if target.is_dir() else target.parent
    log_path = log_dir / 'normalize-audio.log'
    errors = []

    for i, fp in enumerate(files, 1):
        if shutdown_requested:
            print(f"\nStopped after {i-1} files (shutdown requested)")
            break

        rel = fp.relative_to(target) if target.is_dir() and str(fp).startswith(str(target)) else fp.name
        print(f"[{i}/{len(files)}] {rel}")

        status, msg = process_file(fp, dry_run=args.dry_run, skip_stereo=args.skip_stereo, lra_check=args.lra_check)
        stats[status] = stats.get(status, 0) + 1

        icons = {'done': '  +', 'skip': '  -', 'error': '  !', 'would_process': '  >'}
        print(f"{icons.get(status, '  ?')} {msg}")

        if status == 'error':
            errors.append((rel, msg))

        if not args.dry_run:
            with open(log_path, 'a') as f:
                f.write(f"{datetime.now().isoformat()} | {status} | {rel} | {msg}\n")

        if args.limit and stats.get('done', 0) + stats.get('would_process', 0) >= args.limit:
            print(f"\nReached limit of {args.limit}")
            break

    # Summary
    print(f"\n{'='*50}")
    if args.dry_run:
        print(f"Would process: {stats.get('would_process', 0)}")
    else:
        print(f"Processed: {stats['done']}")
    print(f"Skipped:   {stats['skip']}")
    print(f"Errors:    {stats.get('error', 0)}")

    if errors:
        print(f"\nFailed files:")
        for rel, msg in errors[:20]:
            print(f"  {rel}: {msg}")

    if not args.dry_run and stats['done'] > 0:
        print(f"\nLog: {log_path}")
        print("Next: run a Jellyfin library scan to pick up the new audio tracks.")
        print("Then set your preferred audio track to 'Normalized Stereo' in playback.")


if __name__ == '__main__':
    main()
