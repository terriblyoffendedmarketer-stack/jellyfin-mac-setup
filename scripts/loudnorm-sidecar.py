#!/usr/bin/env python3
# loudnorm-sidecar.py — Create loudnorm (EBU R128) sidecar files alongside compressor sidecars
# Phase 2 of the two-phase normalization pipeline.
#
# Reads .Normalized Stereo.{lang}.aac compressor sidecar files and creates
# SEPARATE .ldnrm Stereo.{lang}.aac files next to them. Does NOT overwrite
# the compressor versions — both sidecars coexist so the user can switch
# between them in Jellyfin/VLC.
#
# Usage:
#   python3 scripts/loudnorm-sidecar.py ~/Documents/sidecar-loudnorm
#   python3 scripts/loudnorm-sidecar.py ~/Documents/sidecar-loudnorm --workers 8
#   python3 scripts/loudnorm-sidecar.py ~/Documents/sidecar-loudnorm --dry-run
#   python3 scripts/loudnorm-sidecar.py ~/Documents/sidecar-loudnorm --folder "Movies in General"
#
# Can also run directly on the USB drive (slower due to two-pass reads):
#   python3 scripts/loudnorm-sidecar.py "/Volumes/Backup Plus/All Movies"
# Only specific videos (paths of the VIDEO files, one per line — their compressor sidecars are used):
#   python3 scripts/loudnorm-sidecar.py "/Volumes/Backup Plus" --files-from list.txt
#
# Requires: ffmpeg (brew install ffmpeg)
#
# Gotchas:
# - Uses filter_complex (not -af) to avoid "Error reinitializing filters" on edge cases.
# - Writes to a .loudnorming.{lang}.aac temp file, then renames to final name.
#   If interrupted, temp files are cleaned up on next run.
# - The loudnorm filter is two-pass internally (measure then adjust),
#   so each file is read twice by ffmpeg — SSD is much faster than HDD for this.
# - Scans for ANY .Normalized Stereo.{lang}.aac pattern, not just .en —
#   supports all language codes from the compressor script.
# - A non-zero ffmpeg exit is always a failure (temp deleted). Keeping partial output "if > 100 KB" produced
#   truncated sidecars when a run was interrupted.

import subprocess
import sys
import os
import re
import time
import argparse
import signal
from pathlib import Path
from multiprocessing import Pool, Value, Lock
from ctypes import c_int

COMPRESSOR_PATTERN = re.compile(r'\.Normalized Stereo\.([a-z]{2,3})\.aac$')
LOUDNORM = "loudnorm=I=-16:TP=-1.5:LRA=11"

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


def ldnrm_path_for(compressor_path):
    """Given a .Normalized Stereo.xx.aac path, return the .ldnrm Stereo.xx.aac path."""
    s = str(compressor_path)
    return Path(s.replace('.Normalized Stereo.', '.ldnrm Stereo.'))


def extract_lang(filename):
    """Extract language code from a .Normalized Stereo.xx.aac filename."""
    m = COMPRESSOR_PATTERN.search(filename)
    return m.group(1) if m else 'en'


def process_one(args):
    filepath, total, dry_run = args
    filepath = Path(filepath)

    if shutdown_flag and shutdown_flag.value:
        return (str(filepath), 'skip', 'Shutdown requested')

    if not filepath.exists():
        return (str(filepath), 'error', 'Source not found')

    out_path = ldnrm_path_for(filepath)
    if out_path.exists() and out_path.stat().st_size > 1000 and not os.environ.get('SIDECAR_FORCE'):
        with counter_lock:
            counter_skip.value += 1
        return (str(filepath), 'skip', 'ldnrm sidecar already exists')

    file_size = filepath.stat().st_size
    if file_size < 1000:
        return (str(filepath), 'skip', f'Source too small ({file_size} bytes)')

    lang = extract_lang(filepath.name)

    if dry_run:
        size_mb = file_size / (1024 * 1024)
        return (str(filepath), 'would_process', f'{size_mb:.1f}MB → .ldnrm Stereo.{lang}.aac')

    temp_path = filepath.parent / (filepath.stem.split('.Normalized')[0] + f'.loudnorming.{lang}.aac')

    cmd = [
        'ffmpeg', '-y', '-hide_banner', '-loglevel', 'warning',
        '-i', str(filepath),
        '-filter_complex', f'[0:a:0]{LOUDNORM}[norm]',
        '-map', '[norm]',
        '-c:a', 'aac',
        '-b:a', '192k',
        '-ac', '2',
        '-ar', '48000',
        '-metadata', f'title=ldnrm Stereo',
        '-metadata', f'language={lang}',
        str(temp_path)
    ]

    start = time.time()
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired:
        if temp_path.exists():
            temp_path.unlink()
        return (str(filepath), 'error', 'FFmpeg timeout (30 min)')

    # any ffmpeg error = failure: the input is a clean AAC sidecar, and the old "> 100 KB" rule kept
    # half-finished files from interrupted runs as if they were complete
    if result.returncode != 0:
        if temp_path.exists():
            temp_path.unlink()
        stderr = (result.stderr or "")[-200:]
        return (str(filepath), 'error', f'FFmpeg failed: {stderr}')

    elapsed = time.time() - start

    if not temp_path.exists():
        return (str(filepath), 'error', 'Output file not created')

    temp_size = temp_path.stat().st_size
    if temp_size < 1000:
        temp_path.unlink()
        return (str(filepath), 'error', f'Output too small ({temp_size} bytes)')

    try:
        temp_path.replace(out_path)
    except (OSError, PermissionError) as e:
        if temp_path.exists():
            temp_path.unlink()
        return (str(filepath), 'error', f'Rename failed: {e}')

    size_mb = temp_size / (1024 * 1024)

    with counter_lock:
        counter_done.value += 1
        done = counter_done.value

    return (str(filepath), 'done', f'{size_mb:.1f}MB | {elapsed:.0f}s [{done}/{total}]')


def scan_sidecars(path):
    """Find all compressor sidecars (.Normalized Stereo.xx.aac) that don't yet have a ldnrm version."""
    path = Path(path)
    files = []
    for f in sorted(path.rglob('*')):
        if COMPRESSOR_PATTERN.search(f.name) and not f.name.startswith('._'):
            files.append(f)
    return files


def cleanup_temp_files(path):
    path = Path(path)
    count = 0
    for f in path.rglob('*.loudnorming*.aac'):
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
        description='Create ldnrm sidecar files alongside compressor sidecars (Phase 2)'
    )
    parser.add_argument('path', help='Directory containing compressor sidecar .aac files')
    parser.add_argument('--dry-run', action='store_true',
                        help='Preview what would be processed')
    parser.add_argument('--workers', type=int, default=8,
                        help='Parallel worker count (default: 8)')
    parser.add_argument('--limit', type=int, default=0,
                        help='Process at most N files (0 = unlimited)')
    parser.add_argument('--folder', action='append',
                        help='Process specific subfolder(s) only (can repeat)')
    parser.add_argument('--files-from', metavar='LIST',
                        help='Only these VIDEO paths (one per line): uses their .Normalized Stereo.*.aac sidecars')
    parser.add_argument('--force', action='store_true', help='Redo even if an ldnrm sidecar exists; replaces it')
    args = parser.parse_args()

    target = Path(args.path)
    if not target.exists():
        print(f"Error: {target} does not exist")
        sys.exit(1)

    if args.force:
        os.environ['SIDECAR_FORCE'] = '1'   # env, not a global: macOS spawns workers fresh
    if args.files_from:
        files = []
        for line in open(args.files_from, encoding='utf-8'):
            v = Path(line.rstrip('\n'))
            if not line.strip() or not v.parent.is_dir():
                continue
            for t in v.parent.glob('*.loudnorming*.aac'):
                if not t.name.startswith('._'):
                    t.unlink(missing_ok=True)
            prefix = v.stem + '.Normalized Stereo.'
            files.extend(sorted(f for f in v.parent.iterdir()
                                if f.name.startswith(prefix) and COMPRESSOR_PATTERN.search(f.name)))
        print(f"Using list: {args.files_from}")
    elif args.folder:
        cleanup_temp_files(target)
        files = []
        for folder_name in args.folder:
            folder_path = target / folder_name
            if folder_path.exists():
                print(f"Scanning: {folder_path}")
                files.extend(scan_sidecars(folder_path))
            else:
                print(f"Warning: {folder_path} does not exist, skipping")
    else:
        cleanup_temp_files(target)
        print(f"Scanning: {target}")
        files = scan_sidecars(target)

    print(f"Found {len(files)} compressor sidecars")

    already_done = sum(1 for f in files if ldnrm_path_for(f).exists())
    if already_done:
        print(f"  ({already_done} already have ldnrm versions, will be skipped)")

    if not files:
        sys.exit(0)

    if args.limit:
        files = files[:args.limit]

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

    total_files = len(files)
    work_args = [(str(f), total_files, args.dry_run) for f in files]

    stats = {'done': 0, 'skip': 0, 'error': 0, 'would_process': 0}
    errors = []

    print(f"Processing with {args.workers} parallel workers...\n")
    start_time = time.time()

    workers = min(args.workers, len(files))
    with Pool(workers, initializer=init_worker,
              initargs=(done, skip, error, lock, shutdown)) as pool:
        for filepath, status, msg in pool.imap_unordered(process_one, work_args):
            name = Path(filepath).name
            try:
                name = str(Path(filepath).relative_to(target))
            except ValueError:
                pass

            stats[status] = stats.get(status, 0) + 1

            icons = {'done': '+', 'skip': '-', 'error': '!', 'would_process': '>'}
            icon = icons.get(status, '?')
            print(f"  {icon} {name}: {msg}")

            if status == 'error':
                errors.append((name, msg))

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
        for name, msg in errors[:20]:
            print(f"  {name}: {msg}")


if __name__ == '__main__':
    main()
