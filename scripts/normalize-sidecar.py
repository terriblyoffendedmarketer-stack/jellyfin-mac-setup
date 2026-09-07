#!/usr/bin/env python3
# normalize-sidecar.py — Create normalized stereo sidecar audio files
# for better dialogue clarity on home speakers/soundbars/TV.
#
# Creates a separate .aac file next to each movie instead of modifying
# the original. Jellyfin auto-detects these as additional audio tracks.
# VLC can load them manually (Audio > Audio Track > Open Audio File).
#
# ~6x faster than embedding because it only reads the audio stream
# (~80MB) instead of rewriting the entire movie file (~1.5GB).
# Runs 4 parallel workers by default for ~3-4 hour total processing.
#
# Usage:
#   python3 scripts/normalize-sidecar.py "/Volumes/Backup Plus/All Movies"
#   python3 scripts/normalize-sidecar.py "/path/to/folder" --workers 6
#   python3 scripts/normalize-sidecar.py "/path/to/folder" --dry-run
#   python3 scripts/normalize-sidecar.py "/path/to/folder" --skip-stereo
#   python3 scripts/normalize-sidecar.py "/path/to/folder" --lra-check
#   python3 scripts/normalize-sidecar.py "/path/to/folder" --all-tracks
#   python3 scripts/normalize-sidecar.py "/path/to/folder" --compressor-only --all-tracks
#
# Requires: ffmpeg, ffprobe (brew install ffmpeg)
#
# Gotchas:
# - Sidecar naming: "Movie.Normalized Stereo.en.aac" — Jellyfin parses
#   the text between video name and language code as the track title.
# - loudnorm is the CPU bottleneck (~75% of processing time). Without it,
#   processing is ~4x faster but volume varies between movies.
# - USB read speed (~86MB/s) is NOT the bottleneck — CPU encoding is.
#   That's why parallel workers help so much.
# - ExFAT ._* resource fork files must be skipped during scan.
# - ebur128 LRA regex: use re.findall + last match, not re.search
#   (first match is a per-frame value near -70, not the summary).

import subprocess
import json
import sys
import os
import re
import time
import argparse
import signal
from pathlib import Path
from multiprocessing import Pool, Value, Lock
from datetime import datetime
from ctypes import c_int

MEDIA_EXTENSIONS = {'.mkv', '.mp4', '.avi', '.m4v', '.mov', '.ts', '.wmv'}
NORMALIZED_TITLE = "Normalized Stereo"

# ISO 639-2 (3-letter) → ISO 639-1 (2-letter) for sidecar filenames
LANG_MAP = {
    'eng': 'en', 'jpn': 'ja', 'hin': 'hi', 'zho': 'zh', 'cmn': 'zh',
    'kor': 'ko', 'mal': 'ml', 'tam': 'ta', 'tel': 'te', 'spa': 'es',
    'fra': 'fr', 'fre': 'fr', 'deu': 'de', 'ger': 'de', 'ita': 'it',
    'por': 'pt', 'rus': 'ru', 'ara': 'ar', 'tha': 'th', 'vie': 'vi',
    'ind': 'id', 'ben': 'bn', 'urd': 'ur', 'mar': 'mr', 'kan': 'kn',
    'und': 'en',
}


def lang_code(raw):
    """Convert 3-letter language code to 2-letter for sidecar filename."""
    if len(raw) == 2:
        return raw
    return LANG_MAP.get(raw, raw[:2] if len(raw) >= 2 else 'en')


def sidecar_tag(lang='en'):
    return f".Normalized Stereo.{lang}.aac"

# --- Filter chains ---
COMPRESSOR = "acompressor=threshold=0.089:ratio=4:attack=5:release=100:makeup=5:knee=6"
LOUDNORM = "loudnorm=I=-16:TP=-1.5:LRA=11"

SURROUND_51_PAN = (
    "pan=stereo|"
    "FL=1.0*FC+0.707*FL+0.5*BL+0.25*LFE|"
    "FR=1.0*FC+0.707*FR+0.5*BR+0.25*LFE"
)

SURROUND_71_PAN = (
    "pan=stereo|"
    "FL=1.0*FC+0.707*FL+0.5*BL+0.5*SL+0.25*LFE|"
    "FR=1.0*FC+0.707*FR+0.5*BR+0.5*SR+0.25*LFE"
)


def build_filter(pan_prefix, use_loudnorm):
    parts = []
    if pan_prefix:
        parts.append(pan_prefix)
    parts.append(COMPRESSOR)
    if use_loudnorm:
        parts.append(LOUDNORM)
    return ",".join(parts)

LRA_THRESHOLD = 13.0

# Shared counters for progress reporting
counter_done = None
counter_skip = None
counter_error = None
counter_lock = None
shutdown_flag = None


def init_worker(done, skip, error, lock, shutdown):
    global counter_done, counter_skip, counter_error, counter_lock, shutdown_flag
    counter_done = done
    counter_skip = skip
    counter_error = error
    counter_lock = lock
    shutdown_flag = shutdown
    signal.signal(signal.SIGINT, signal.SIG_IGN)


def probe_file(filepath):
    cmd = [
        'ffprobe', '-v', 'quiet',
        '-print_format', 'json',
        '-show_streams', '-show_format',
        str(filepath)
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
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


def sidecar_path(filepath, lang='en'):
    """Get the sidecar .aac path for a given video file and language."""
    return filepath.parent / (filepath.stem + sidecar_tag(lang))


def has_sidecar(filepath, lang='en'):
    return sidecar_path(filepath, lang).exists()


def has_any_sidecar(filepath):
    """Check if any .Normalized Stereo.*.aac sidecar exists."""
    pattern = filepath.stem + ".Normalized Stereo.*.aac"
    return any(filepath.parent.glob(pattern))


def pick_filter(channels, channel_layout, use_loudnorm=True):
    if channels >= 8 or '7.1' in channel_layout:
        return build_filter(SURROUND_71_PAN, use_loudnorm), "7.1→stereo", True
    elif channels >= 6 or '5.1' in channel_layout:
        return build_filter(SURROUND_51_PAN, use_loudnorm), "5.1→stereo", True
    elif channels > 2:
        return build_filter(None, use_loudnorm), f"{channels}ch→stereo", True
    else:
        return build_filter(None, use_loudnorm), f"{channels}ch stereo", False


def measure_lra(filepath, stream_index):
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


def process_one(args):
    """Worker function: process a single track. Returns (filepath, status, msg)."""
    filepath, track_index, track_lang, skip_stereo, lra_check, total, dry_run, use_loudnorm = args
    filepath = Path(filepath)

    if shutdown_flag and shutdown_flag.value:
        return (str(filepath), 'skip', 'Shutdown requested')

    probe_data = probe_file(filepath)
    if not probe_data:
        return (str(filepath), 'error', "Could not probe file")

    audio_streams = get_audio_streams(probe_data)
    if not audio_streams:
        return (str(filepath), 'skip', "No audio streams")

    if track_index >= len(audio_streams):
        return (str(filepath), 'skip', f"Track {track_index} not found")

    source = audio_streams[track_index]
    lang_raw = track_lang or source['language']
    lang = lang_code(lang_raw) if lang_raw != 'und' else 'en'

    if has_sidecar(filepath, lang):
        return (str(filepath), 'skip', f"Sidecar .{lang}.aac already exists")

    channels = source['channels']
    layout = source['channel_layout']

    audio_filter, source_desc, is_surround = pick_filter(channels, layout, use_loudnorm)
    source_desc = f"[{lang}] {source_desc}"

    if skip_stereo and not is_surround:
        return (str(filepath), 'skip', f"Stereo source (--skip-stereo)")

    if lra_check and not is_surround:
        lra = measure_lra(filepath, source['index'])
        if lra is not None and lra <= LRA_THRESHOLD:
            return (str(filepath), 'skip', f"Stereo LRA OK ({lra:.1f} <= {LRA_THRESHOLD})")
        if lra is not None:
            source_desc = f"{source_desc} LRA={lra:.1f}"
        elif lra is None:
            source_desc = f"{source_desc} LRA=unknown"

    if dry_run:
        return (str(filepath), 'would_process', source_desc)

    out_path = sidecar_path(filepath, lang)
    temp_path = filepath.parent / (filepath.stem + f".normalizing.{lang}.aac")

    cmd = [
        'ffmpeg', '-y', '-hide_banner', '-loglevel', 'warning',
        '-i', str(filepath),
        '-filter_complex', f'[0:a:{track_index}]{audio_filter}[norm]',
        '-map', '[norm]',
        '-c:a', 'aac',
        '-b:a', '192k',
        '-ac', '2',
        '-ar', '48000',
        '-metadata', f'title={NORMALIZED_TITLE}',
        '-metadata', f'language={lang_raw}',
        str(temp_path)
    ]

    start = time.time()
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired:
        if temp_path.exists():
            temp_path.unlink()
        return (str(filepath), 'error', "FFmpeg timeout (30 min)")

    if result.returncode != 0 and not (temp_path.exists() and temp_path.stat().st_size > 100000):
        if is_surround and 'pan=' in audio_filter:
            fallback = build_filter(None, use_loudnorm)
            cmd_fb = [
                'ffmpeg', '-y', '-hide_banner', '-loglevel', 'warning',
                '-i', str(filepath),
                '-filter_complex', f'[0:a:{track_index}]{fallback}[norm]',
                '-map', '[norm]',
                '-c:a', 'aac',
                '-b:a', '192k',
                '-ac', '2',
                '-ar', '48000',
                '-metadata', f'title={NORMALIZED_TITLE}',
                '-metadata', f'language={lang_raw}',
                str(temp_path)
            ]
            try:
                result = subprocess.run(cmd_fb, capture_output=True, text=True, timeout=1800)
            except subprocess.TimeoutExpired:
                pass

        if not (temp_path.exists() and temp_path.stat().st_size > 100000):
            if temp_path.exists():
                temp_path.unlink()
            stderr = (result.stderr or "")[-200:]
            return (str(filepath), 'error', f"FFmpeg failed: {stderr}")

    elapsed = time.time() - start

    if not temp_path.exists():
        return (str(filepath), 'error', "Output file not created")

    temp_size = temp_path.stat().st_size
    if temp_size < 1000:
        temp_path.unlink()
        return (str(filepath), 'error', f"Output too small ({temp_size} bytes)")

    try:
        temp_path.replace(out_path)
    except (OSError, PermissionError):
        try:
            subprocess.run(['chflags', 'nouchg', str(out_path)], timeout=5)
            temp_path.replace(out_path)
        except (OSError, PermissionError) as e:
            if temp_path.exists():
                temp_path.unlink()
            return (str(filepath), 'error', f"Rename failed: {e}")

    size_mb = temp_size / (1024 * 1024)

    with counter_lock:
        counter_done.value += 1
        done = counter_done.value

    return (str(filepath), 'done', f"{source_desc} | {size_mb:.1f}MB | {elapsed:.0f}s [{done}/{total}]")


def scan_media(path):
    path = Path(path)
    if path.is_file():
        return [path] if path.suffix.lower() in MEDIA_EXTENSIONS else []
    files = []
    for f in sorted(path.rglob('*')):
        if (f.suffix.lower() in MEDIA_EXTENSIONS
                and '.normalizing' not in f.name
                and not f.name.startswith('._')):
            files.append(f)
    return files


def cleanup_temp_files(path):
    path = Path(path)
    if path.is_file():
        return
    count = 0
    for f in path.rglob('*.normalizing*.aac'):
        try:
            if not f.name.startswith('._'):
                f.unlink()
                count += 1
        except OSError:
            pass
    if count:
        print(f"Cleaned up {count} leftover temp file(s)")


def main():
    parser = argparse.ArgumentParser(
        description='Create normalized stereo sidecar audio files (parallel)'
    )
    parser.add_argument('path', help='Media file or directory to process')
    parser.add_argument('--dry-run', action='store_true',
                        help='Preview what would be processed')
    parser.add_argument('--workers', type=int, default=4,
                        help='Parallel worker count (default: 4)')
    parser.add_argument('--limit', type=int, default=0,
                        help='Process at most N files (0 = unlimited)')
    parser.add_argument('--skip-stereo', action='store_true',
                        help='Skip files that already have stereo audio')
    parser.add_argument('--lra-check', action='store_true',
                        help='For stereo files: scan full audio and skip if LRA <= 13')
    parser.add_argument('--folder', action='append',
                        help='Process specific subfolder(s) only (can repeat)')
    parser.add_argument('--compressor-only', action='store_true',
                        help='Skip loudnorm (4x faster, slight volume variation between movies)')
    parser.add_argument('--all-tracks', action='store_true',
                        help='Process all audio tracks (one sidecar per language, not just track 0)')
    args = parser.parse_args()

    target = Path(args.path)
    if not target.exists():
        print(f"Error: {target} does not exist")
        sys.exit(1)

    cleanup_temp_files(target)

    # Scan files
    if args.folder:
        files = []
        for folder_name in args.folder:
            folder_path = target / folder_name
            if folder_path.exists():
                print(f"Scanning: {folder_path}")
                files.extend(scan_media(folder_path))
            else:
                print(f"Warning: {folder_path} does not exist, skipping")
    else:
        print(f"Scanning: {target}")
        files = scan_media(target)

    print(f"Found {len(files)} media files")

    if not files:
        sys.exit(0)

    if args.limit:
        files = files[:args.limit]

    # Shared state
    done = Value(c_int, 0)
    skip = Value(c_int, 0)
    error = Value(c_int, 0)
    lock = Lock()
    shutdown = Value(c_int, 0)

    def handle_signal(sig, frame):
        shutdown.value = 1
        print("\nShutdown requested — finishing current files then stopping...")

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    use_loudnorm = not args.compressor_only

    # Build work items: one per (file, track) pair
    if args.all_tracks:
        work_items = []
        for f in files:
            probe_data = probe_file(f)
            if not probe_data:
                work_items.append((str(f), 0, None, args.skip_stereo, args.lra_check, 0, args.dry_run, use_loudnorm))
                continue
            audio_streams = get_audio_streams(probe_data)
            if not audio_streams:
                work_items.append((str(f), 0, None, args.skip_stereo, args.lra_check, 0, args.dry_run, use_loudnorm))
                continue
            # Group by language, pick best (highest channel count) per language
            by_lang = {}
            for i, s in enumerate(audio_streams):
                raw = s['language']
                lang = lang_code(raw) if raw != 'und' else 'en'
                if lang not in by_lang or s['channels'] > by_lang[lang][1]['channels']:
                    by_lang[lang] = (i, s)
            for lang, (idx, s) in by_lang.items():
                work_items.append((str(f), idx, s['language'], args.skip_stereo, args.lra_check, 0, args.dry_run, use_loudnorm))
        print(f"All-tracks mode: {len(work_items)} track(s) across {len(files)} files")
    else:
        work_items = [
            (str(f), 0, None, args.skip_stereo, args.lra_check, 0, args.dry_run, use_loudnorm)
            for f in files
        ]

    total_files = len(work_items)
    work_args = [(f, ti, tl, ss, lc, total_files, dr, ul)
                 for f, ti, tl, ss, lc, _, dr, ul in work_items]

    log_dir = target if target.is_dir() else target.parent
    log_path = log_dir / 'normalize-sidecar.log'

    stats = {'done': 0, 'skip': 0, 'error': 0, 'would_process': 0}
    errors = []

    print(f"Processing with {args.workers} parallel workers...\n")
    start_time = time.time()

    workers = min(args.workers, len(files))
    with Pool(workers, initializer=init_worker,
              initargs=(done, skip, error, lock, shutdown)) as pool:
        for filepath, status, msg in pool.imap_unordered(process_one, work_args):
            rel = Path(filepath).name
            try:
                rel = str(Path(filepath).relative_to(target))
            except ValueError:
                pass

            stats[status] = stats.get(status, 0) + 1

            icons = {'done': '+', 'skip': '-', 'error': '!', 'would_process': '>'}
            icon = icons.get(status, '?')
            print(f"  {icon} {rel}: {msg}")

            if status == 'error':
                errors.append((rel, msg))

            if not args.dry_run:
                with open(log_path, 'a') as f:
                    f.write(f"{datetime.now().isoformat()} | {status} | {rel} | {msg}\n")

            if shutdown.value:
                pool.terminate()
                break

    elapsed = time.time() - start_time
    hours = elapsed / 3600
    minutes = (elapsed % 3600) / 60

    print(f"\n{'='*50}")
    print(f"Time: {int(hours)}h {int(minutes)}m")
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


if __name__ == '__main__':
    main()
