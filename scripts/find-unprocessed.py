#!/usr/bin/env python3
# find-unprocessed.py — Find ONLY the videos on the hard drive that still need audio sidecars, without opening any video.
# Reads folder listings (filenames) of "All Movies" and "TV", so 1 TB of films takes seconds, not hours.
# Sorts what it finds into Movies (by category folder) and TV (by show), and flags files in the wrong place.
#
# Usage:
#   python3 scripts/find-unprocessed.py                          # report: films/episodes missing a compressor sidecar
#   python3 scripts/find-unprocessed.py --mode loudnorm          # have a compressor sidecar but no ldnrm one
#   python3 scripts/find-unprocessed.py --out /tmp/todo.txt      # also write the video paths, one per line
#   python3 scripts/find-unprocessed.py --only movies            # or --only tv
#   python3 scripts/find-unprocessed.py --drive "/Volumes/Backup Plus" --no-subs
# Then: python3 scripts/normalize-sidecar.py "/Volumes/Backup Plus" --files-from /tmp/todo.txt --compressor-only --all-tracks
# Used by "Normalize Hard Drive.command" (drive root). Requires: python3; ffprobe only for the subtitle check.
#
# Gotchas:
#   - "Processed" = a sibling file named "<video name>.Normalized Stereo.<lang>.aac" exists (the sidecar naming
#     normalize-sidecar.py writes). Checked by name only — never ffprobe the whole drive, that was the slow part.
#   - Folders containing a ".ignore" file are skipped (Jellyfin skips them too: Monogatari BD source, Kizumonogatari).
#   - exFAT "._*" AppleDouble files and "sample" clips are not videos to process.
#   - Drive layout: All Movies/<Category>/<Film folder>/film.mkv and TV/<Show>/[Season xx/]episode.mkv.
#     Videos anywhere else on the drive are invisible to Jellyfin; they are listed as "outside library folders".

import argparse
import os
import re
import subprocess
import sys
from collections import defaultdict

VIDEO_EXT = {'.mkv', '.mp4', '.avi', '.m4v', '.mov', '.ts', '.wmv'}
SUB_EXT = {'.srt', '.ass', '.ssa', '.sub', '.vtt'}
EPISODE_RE = re.compile(r'(?i)(\bS\d{1,2}\s*E\d{1,3}\b|\b\d{1,2}x\d{2}\b|\bEp?\s?\d{2,3}\b|\bEpisode\s*\d+)')
MOVIES_DIR, TV_DIR = 'All Movies', 'TV'


def is_video(name):
    if name.startswith('._') or '.normalizing' in name or '.loudnorming' in name:
        return False
    return os.path.splitext(name)[1].lower() in VIDEO_EXT


def is_sample(path, name):
    if 'sample' not in name.lower():
        return False
    try:
        return os.path.getsize(path) < 300 * 1024 * 1024
    except OSError:
        return False


def walk(top):
    """Yield (dirpath, filenames) for every folder under top, skipping hidden and .ignore'd folders."""
    for dirpath, dirnames, filenames in os.walk(top):
        if '.ignore' in filenames:
            dirnames[:] = []
            continue
        dirnames[:] = sorted(d for d in dirnames if not d.startswith('.'))
        yield dirpath, sorted(filenames)


def needs_work(stem, names, mode):
    comp = [n for n in names if n.startswith(stem + '.Normalized Stereo.') and n.endswith('.aac')]
    if mode == 'compressor':
        return not comp
    # loudnorm: every compressor sidecar needs its ldnrm twin
    return bool(comp) and any(n.replace('.Normalized Stereo.', '.ldnrm Stereo.') not in names for n in comp)


def has_external_sub(names):
    return any(os.path.splitext(n)[1].lower() in SUB_EXT and not n.startswith('._') for n in names)


def has_embedded_sub(path):
    try:
        r = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 's', '-show_entries', 'stream=index',
                            '-of', 'csv=p=0', path], capture_output=True, text=True, timeout=60)
        return r.returncode != 0 or bool(r.stdout.strip())  # unreadable -> can't tell, don't nag
    except (OSError, subprocess.TimeoutExpired):
        return True  # can't tell — don't nag


def main():
    ap = argparse.ArgumentParser(description='List drive videos that still need normalized-audio sidecars')
    ap.add_argument('--drive', default='/Volumes/Backup Plus')
    ap.add_argument('--mode', choices=['compressor', 'loudnorm'], default='compressor')
    ap.add_argument('--out', help='write the video paths to process here, one per line')
    ap.add_argument('--no-subs', action='store_true', help='skip the missing-subtitles check')
    ap.add_argument('--only', choices=['movies', 'tv'], help='look in All Movies or TV only')
    a = ap.parse_args()

    if not os.path.isdir(a.drive):
        sys.exit(f"Drive not found at {a.drive} — plug it in first.")

    todo = []                          # (kind, group, path, has_subs)
    movies = defaultdict(list)         # category -> [rel path]
    tv = defaultdict(list)             # show -> [rel path]
    misplaced = []                     # (path, reason)
    counted = {'Movies': 0, 'TV': 0}

    for kind, top in (('Movies', MOVIES_DIR), ('TV', TV_DIR)):
        if a.only and a.only != kind.lower():
            continue
        root = os.path.join(a.drive, top)
        if not os.path.isdir(root):
            print(f"  (no '{top}' folder on the drive)")
            continue
        for dirpath, names in walk(root):
            rel_dir = os.path.relpath(dirpath, root)
            parts = [] if rel_dir == '.' else rel_dir.split(os.sep)
            group = parts[0] if parts else '(loose)'
            vids = [n for n in names if is_video(n) and not is_sample(os.path.join(dirpath, n), n)]
            if kind == 'Movies' and vids:
                if not parts:
                    misplaced.append((os.path.join(top, vids[0]), 'loose in All Movies — put it in a category folder'))
                eps = [n for n in vids if EPISODE_RE.search(n)]
                if len(eps) >= 3:
                    misplaced.append((os.path.join(top, rel_dir), f'{len(eps)} episode-named files — TV show? move to TV/'))
            if kind == 'TV' and vids and not parts:
                misplaced.append((os.path.join(top, vids[0]), 'loose in TV — put it in a folder named after the show'))
            for n in vids:
                counted[kind] += 1
                stem = os.path.splitext(n)[0]
                if needs_work(stem, names, a.mode):
                    path = os.path.join(dirpath, n)
                    todo.append((kind, group, path, has_external_sub(names)))
                    (movies if kind == 'Movies' else tv)[group].append(os.path.relpath(path, root))

    # videos outside All Movies / TV (two levels deep, so a big backup folder isn't crawled)
    for e in sorted(os.scandir(a.drive), key=lambda e: e.name):
        if e.name.startswith('.') or e.name in (MOVIES_DIR, TV_DIR):
            continue
        if e.is_file() and is_video(e.name):
            misplaced.append((e.name, 'on the drive root — Jellyfin never sees it'))
        elif e.is_dir():
            try:
                for f in os.scandir(e.path):
                    if f.is_file() and is_video(f.name):
                        misplaced.append((os.path.join(e.name, f.name), 'outside All Movies / TV — Jellyfin never sees it'))
                    elif f.is_dir() and not f.name.startswith('.'):
                        if any(is_video(x) for x in os.listdir(f.path)):
                            misplaced.append((os.path.join(e.name, f.name), 'outside All Movies / TV — Jellyfin never sees it'))
            except OSError:
                pass

    what = 'compressor sidecar' if a.mode == 'compressor' else 'loudnorm (ldnrm) sidecar'
    print(f"Checked {counted['Movies']} movie files and {counted['TV']} TV files by name — "
          f"{len(todo)} need a {what}.\n")
    if movies:
        print(f"MOVIES ({sum(map(len, movies.values()))})")
        for cat in sorted(movies):
            print(f"  {cat}")
            for p in movies[cat]:
                print(f"    - {p.split(os.sep, 1)[-1]}")
        print()
    if tv:
        print(f"TV ({sum(map(len, tv.values()))} episodes)")
        for show in sorted(tv):
            print(f"  {show}: {len(tv[show])} episode(s)")
        print()
    if misplaced:
        print("CHECK THESE (wrong place):")
        for p, why in misplaced:
            print(f"  ! {p}  — {why}")
        print()

    if not a.no_subs and todo:
        missing = [p for k, g, p, ext in todo if not ext and not has_embedded_sub(p)]
        if missing:
            print(f"MISSING SUBTITLES ({len(missing)}) — find them yourself, nothing is auto-downloaded:")
            for p in missing:
                print(f"  - {os.path.relpath(p, a.drive)}")
        else:
            print("Subtitles: all new items have them.")
        print()

    if a.out:
        with open(a.out, 'w', encoding='utf-8') as f:
            for _, _, p, _ in todo:
                f.write(p + '\n')


if __name__ == '__main__':
    main()
