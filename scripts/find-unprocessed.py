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
#   python3 scripts/find-unprocessed.py --force-path "/Volumes/Backup Plus/All Movies/Asian Movies/Oldboy (2003)"
#                                         # list EVERY video under that folder, sidecar or not (manual redo)
#   python3 scripts/find-unprocessed.py --audit                  # also catch CUT-SHORT sidecars (reads each film's
#                                         # length from its header: a few minutes for the whole drive)
#   python3 scripts/find-unprocessed.py --drive "/Volumes/Backup Plus" --no-subs
# Then: python3 scripts/normalize-sidecar.py "/Volumes/Backup Plus" --files-from /tmp/todo.txt --compressor-only --all-tracks
# Used by "Normalize Hard Drive.command" (drive root). Requires: python3; ffprobe only for the subtitle check.
#
# Gotchas:
#   - "Processed" = a sibling "<video name>.Normalized Stereo.<lang>.aac" exists AND is newer than the video AND is
#     not tiny. Name + date + size only (no file opened) — never ffprobe the whole drive, that was the slow part.
#   - Re-downloads: delete a film, re-download it under the same name later -> the old sidecar would match by name.
#     The new video's modified date is newer than the old sidecar, so it's listed as "re-downloaded" and redone
#     (callers pass --force). On 2026-10-19 all 948 sidecars were newer than their videos: no false alarms.
#   - Cut-short sidecars (interrupted ffmpeg, kept by the old "> 100 KB" rule): a 192 kbps sidecar is ~24,000 bytes
#     per second, so size / 24000 = minutes covered. --audit compares that with the film's length (ffprobe header);
#     quiet films encode smaller (E.T. looked 84% done but was complete), so suspects are confirmed by counting AAC
#     frames (-count_packets, <1 s). ffprobe's format=duration on a raw .aac is a bitrate GUESS — never trust it.
#   - Extras folders (Extras, Featurettes, Behind The Scenes, ...) are skipped: Jellyfin shows them as bonus clips.
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
EXTRAS_DIRS = {'extras', 'featurettes', 'behind the scenes', 'deleted scenes', 'interviews', 'trailers', 'bonus'}
MIN_SIDECAR = 100_000   # bytes; anything smaller is a broken/aborted sidecar
AAC_BYTES_PER_SEC = 24_000   # -b:a 192k, measured 24.0-24.3 KB/s on real sidecars
AUDIT = False


def aac_seconds(path):
    """Exact length of an ADTS .aac sidecar: frames x 1024 / sample rate (its header 'duration' is a bad guess)."""
    try:
        r = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'a:0', '-count_packets', '-show_entries',
                            'stream=sample_rate,nb_read_packets', '-of', 'csv=p=0', path],
                           capture_output=True, text=True, timeout=120)
        rate, packets = r.stdout.strip().split(',')[:2]
        return int(packets) * 1024 / int(rate)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return float('inf')   # can't tell -> don't flag


def video_seconds(path):
    try:
        r = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', path],
                           capture_output=True, text=True, timeout=60)
        return float(r.stdout.strip() or 0)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return 0.0


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
        dirnames[:] = sorted(d for d in dirnames
                             if not d.startswith('.') and d.split(' & ')[0].strip().lower() not in EXTRAS_DIRS)
        yield dirpath, sorted(filenames)


def _stat(path):
    try:
        st = os.stat(path)
        return st.st_mtime, st.st_size
    except OSError:
        return 0, 0


def needs_work(dirpath, video, names, mode):
    """Return why this video needs work ('' = it doesn't). Uses names + stat only."""
    stem = os.path.splitext(video)[0]
    v_time, _ = _stat(os.path.join(dirpath, video))
    comp = [n for n in names if n.startswith(stem + '.Normalized Stereo.') and n.endswith('.aac')]
    if mode == 'compressor':
        if not comp:
            return 'new'
        stats = [_stat(os.path.join(dirpath, n)) for n in comp]
        if any(size < MIN_SIDECAR for _, size in stats):
            return 'broken sidecar'
        if all(t + 60 < v_time for t, _ in stats):
            return 're-downloaded (video newer than its sidecar)'
        if AUDIT:
            dur = video_seconds(os.path.join(dirpath, video))
            best = max(comp, key=lambda n: _stat(os.path.join(dirpath, n))[1])
            if dur > 120 and _stat(os.path.join(dirpath, best))[1] / AAC_BYTES_PER_SEC < 0.9 * dur:
                covered = aac_seconds(os.path.join(dirpath, best))   # suspect -> exact frame count
                if covered < 0.97 * dur:
                    return f'cut short ({covered / 60:.0f} of {dur / 60:.0f} min)'
        return ''
    # loudnorm: every compressor sidecar needs a healthy ldnrm twin made after it
    for n in comp:
        ld = n.replace('.Normalized Stereo.', '.ldnrm Stereo.')
        if ld not in names:
            return 'new'
        c_time, c_size = _stat(os.path.join(dirpath, n))
        l_time, l_size = _stat(os.path.join(dirpath, ld))
        if l_size < MIN_SIDECAR or l_size < 0.85 * c_size:
            return 'broken sidecar'
        if l_time + 60 < c_time:
            return 'redone compressor (ldnrm older than it)'
    return ''


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
    ap.add_argument('--force-path', help='list every video under this folder/file, whatever its sidecars')
    ap.add_argument('--audit', action='store_true', help='also flag cut-short sidecars (reads each film header)')
    a = ap.parse_args()
    global AUDIT
    AUDIT = a.audit

    if a.force_path:
        fp = a.force_path.rstrip('/')
        if os.path.isfile(fp):
            vids = [fp] if is_video(os.path.basename(fp)) else []
        else:
            vids = [os.path.join(d, n) for d, names in walk(fp) for n in names if is_video(n)
                    and not is_sample(os.path.join(d, n), n)]
        if a.mode == 'loudnorm':   # loudnorm needs the compressor sidecar first
            vids = [v for v in vids if any(n.startswith(os.path.splitext(os.path.basename(v))[0] + '.Normalized Stereo.')
                                           for n in os.listdir(os.path.dirname(v)))]
        print(f"Redo (forced): {len(vids)} video(s) under {fp}")
        for v in vids:
            print(f"  - {os.path.relpath(v, os.path.dirname(fp))}")
        if a.out:
            with open(a.out, 'w', encoding='utf-8') as f:
                f.writelines(v + '\n' for v in vids)
        return

    if not os.path.isdir(a.drive):
        sys.exit(f"Drive not found at {a.drive} — plug it in first.")

    todo = []                          # (kind, group, path, has_subs)
    movies = defaultdict(list)         # category -> [rel path]
    tv = defaultdict(list)             # show -> [rel path]
    misplaced = []                     # (path, reason)
    orphans = []                       # sidecars whose video is gone
    reasons = defaultdict(int)
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
            stems = {os.path.splitext(n)[0] for n in names if is_video(n)}
            orphans += [os.path.join(dirpath, n) for n in names if not n.startswith('._') and n.endswith('.aac')
                        and ' Stereo.' in n and n.split('.Normalized Stereo.')[0].split('.ldnrm Stereo.')[0] not in stems]
            for n in vids:
                counted[kind] += 1
                why = needs_work(dirpath, n, names, a.mode)
                if why:
                    reasons[why.split(' (')[0]] += 1
                    path = os.path.join(dirpath, n)
                    todo.append((kind, group, path, has_external_sub(names)))
                    tag = '' if why == 'new' else f'   [{why}]'
                    (movies if kind == 'Movies' else tv)[group].append(os.path.relpath(path, root) + tag)

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
          f"{len(todo)} need a {what}.")
    extra = {k: v for k, v in reasons.items() if k != 'new'}
    if extra:
        print("  of which: " + ", ".join(f"{v} {k}" for k, v in extra.items()) + " — these get redone")
    print()
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

    if orphans:
        print(f"LEFTOVER SIDECARS ({len(orphans)}) — their video is gone (deleted film?). Harmless; delete if you like:")
        for p in orphans[:15]:
            print(f"  - {os.path.relpath(p, a.drive)}")
        if len(orphans) > 15:
            print(f"  ... and {len(orphans) - 15} more")
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
