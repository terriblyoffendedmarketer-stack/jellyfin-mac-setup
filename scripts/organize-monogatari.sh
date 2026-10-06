#!/bin/bash
# organize-monogatari.sh — Copy Monogatari BD files into Jellyfin-friendly structure
# Usage: bash organize-monogatari.sh [--dry-run]
# Requires: ~40GB free on the drive (copies, does not move)
#
# Maps the [DB] BD release folder structure to TMDB season/episode numbering
# for the "Monogatari" series (TMDB ID 46195).
#
# TMDB structure:
#   S01: Bakemonogatari (12 eps)
#   S02: Nisemonogatari (11 eps)
#   S03: Monogatari Second Season (23 eps — Neko Shiro + Kabuki + Otori + Oni + Koimo)
#   S04: Owarimonogatari (12-13 eps)
#   S00 Specials: Bake 13-15, Neko Kuro, Hana, Tsuki, Koyomi, Owari S2, Zoku Owari
#   Kizumonogatari: 3 movies (separate on TMDB, kept in own folder)
#
# Gotchas:
# - exFAT does not support hardlinks or symlinks — must do full copies
# - macOS ._ resource fork files in the source must be skipped
# - BD has 13 Owarimonogatari eps, TMDB has 12 — ep 13 will show without metadata
# - Hanamonogatari is in BD's "Second Season" folder but TMDB puts it in Specials
# - Kizumonogatari movies don't belong in the TV series on TMDB

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "=== DRY RUN — no files will be copied ==="
    echo ""
fi

SRC="/Volumes/Backup Plus/TV/Monogatari Series [BD]"
DEST="/Volumes/Backup Plus/TV/Monogatari Series"
SERIES="Monogatari Series"

TOTAL=0
ERRORS=0

copy_ep() {
    local src_file="$1"
    local dest_file="$2"

    if [[ ! -f "$src_file" ]]; then
        echo "  ERROR: Source not found: $src_file"
        ERRORS=$((ERRORS + 1))
        return
    fi

    if [[ -f "$dest_file" ]]; then
        echo "  SKIP (exists): $(basename "$dest_file")"
        TOTAL=$((TOTAL + 1))
        return
    fi

    if $DRY_RUN; then
        echo "  WOULD COPY: $(basename "$src_file") → $(basename "$dest_file")"
    else
        cp "$src_file" "$dest_file"
        echo "  COPIED: $(basename "$dest_file")"
    fi
    TOTAL=$((TOTAL + 1))
}

# Create season folders
for folder in "Season 01" "Season 02" "Season 03" "Season 04" "Specials"; do
    if $DRY_RUN; then
        echo "WOULD CREATE: $DEST/$folder/"
    else
        mkdir -p "$DEST/$folder"
    fi
done

echo ""
echo "=== Season 01: Bakemonogatari (12 eps) ==="
for i in $(seq 1 12); do
    ep=$(printf "%02d" $i)
    copy_ep "$SRC/01 Monogatari First Season/01 Bakemonogatari/[DB]Bakemonogatari_-_${ep}_(10bit_BD1080p_x265).mkv" \
            "$DEST/Season 01/${SERIES} S01E${ep}.mkv"
done

echo ""
echo "=== Season 02: Nisemonogatari (11 eps) ==="
for i in $(seq 1 11); do
    ep=$(printf "%02d" $i)
    copy_ep "$SRC/01 Monogatari First Season/02 Nisemonogatari/[DB]Nisemonogatari_-_${ep}_(10bit_BD1080p_x265).mkv" \
            "$DEST/Season 02/${SERIES} S02E${ep}.mkv"
done

echo ""
echo "=== Season 03: Second Season (23 eps) ==="

# Arc 1: Nekomonogatari Shiro → S03E01-05
offset=0
for i in $(seq 1 5); do
    ep_src=$(printf "%02d" $i)
    ep_dest=$(printf "%02d" $((i + offset)))
    copy_ep "$SRC/02 Monogatari Second Season/Arc 01 Nekomonogatari Shiro/[DB]Nekomonogatari (Shiro)_-_${ep_src}_(10bit_BD1080p_x265).mkv" \
            "$DEST/Season 03/${SERIES} S03E${ep_dest}.mkv"
done

# Arc 2: Kabukimonogatari → S03E06-09
offset=5
for i in $(seq 1 4); do
    ep_src=$(printf "%02d" $i)
    ep_dest=$(printf "%02d" $((i + offset)))
    copy_ep "$SRC/02 Monogatari Second Season/Arc 02 Kabukimonogatari/[DB]Kabukimonogatari_-_${ep_src}_(10bit_BD1080p_x265).mkv" \
            "$DEST/Season 03/${SERIES} S03E${ep_dest}.mkv"
done

# Arc 3: Otorimonogatari → S03E10-13
offset=9
for i in $(seq 1 4); do
    ep_src=$(printf "%02d" $i)
    ep_dest=$(printf "%02d" $((i + offset)))
    copy_ep "$SRC/02 Monogatari Second Season/Arc 03 Otorimonogatari/[DB]Otorimonogatari_-_${ep_src}_(10bit_BD1080p_x265).mkv" \
            "$DEST/Season 03/${SERIES} S03E${ep_dest}.mkv"
done

# Arc 4: Onimonogatari → S03E14-17
offset=13
for i in $(seq 1 4); do
    ep_src=$(printf "%02d" $i)
    ep_dest=$(printf "%02d" $((i + offset)))
    copy_ep "$SRC/02 Monogatari Second Season/Arc 04 Onimonogatari/[DB]Onimonogatari_-_${ep_src}_(10bit_BD1080p_x265).mkv" \
            "$DEST/Season 03/${SERIES} S03E${ep_dest}.mkv"
done

# Arc 5: Koimonogatari → S03E18-23
offset=17
for i in $(seq 1 6); do
    ep_src=$(printf "%02d" $i)
    ep_dest=$(printf "%02d" $((i + offset)))
    copy_ep "$SRC/02 Monogatari Second Season/Arc 05 Koimonogatari/[DB]Koimonogatari_-_${ep_src}_(10bit_BD1080p_x265).mkv" \
            "$DEST/Season 03/${SERIES} S03E${ep_dest}.mkv"
done

echo ""
echo "=== Season 04: Owarimonogatari (13 eps, TMDB has 12) ==="
for i in $(seq 1 13); do
    ep=$(printf "%02d" $i)
    copy_ep "$SRC/03 Monogatari Final Season/02 Owarimonogatari/[DB]Owarimonogatari_-_${ep}_(10bit_BD1080p_x265).mkv" \
            "$DEST/Season 04/${SERIES} S04E${ep}.mkv"
done

echo ""
echo "=== Specials (Season 00) ==="

# Bakemonogatari 13-15 → S00E02-04
echo "  --- Bakemonogatari web episodes (Tsubasa Cat 3-5) ---"
for i in 13 14 15; do
    ep_src=$(printf "%02d" $i)
    sp_num=$((i - 11))  # 13→02, 14→03, 15→04
    ep_dest=$(printf "%02d" $sp_num)
    copy_ep "$SRC/01 Monogatari First Season/01 Bakemonogatari/[DB]Bakemonogatari_-_${ep_src}_(10bit_BD1080p_x265).mkv" \
            "$DEST/Specials/${SERIES} S00E${ep_dest}.mkv"
done

# Nekomonogatari Kuro 01-04 → S00E06-09
echo "  --- Nekomonogatari Kuro ---"
for i in $(seq 1 4); do
    ep_src=$(printf "%02d" $i)
    ep_dest=$(printf "%02d" $((i + 5)))
    copy_ep "$SRC/01 Monogatari First Season/03 Nekomonogatari (Kuro)/[DB]Nekomonogatari (Kuro)_-_${ep_src}_(10bit_BD1080p_x265).mkv" \
            "$DEST/Specials/${SERIES} S00E${ep_dest}.mkv"
done

# Hanamonogatari 01-05 → S00E13-17
echo "  --- Hanamonogatari ---"
for i in $(seq 1 5); do
    ep_src=$(printf "%02d" $i)
    ep_dest=$(printf "%02d" $((i + 12)))
    copy_ep "$SRC/02 Monogatari Second Season/Arc 06 Hanamonogatari/[DB]Hanamonogatari_-_${ep_src}_(10bit_BD1080p_x265).mkv" \
            "$DEST/Specials/${SERIES} S00E${ep_dest}.mkv"
done

# Tsukimonogatari 01-04 → S00E18-21
echo "  --- Tsukimonogatari ---"
for i in $(seq 1 4); do
    ep_src=$(printf "%02d" $i)
    ep_dest=$(printf "%02d" $((i + 17)))
    copy_ep "$SRC/03 Monogatari Final Season/01 Tsukimonogatari/[DB]Tsukimonogatari_-_${ep_src}_(10bit_BD1080p_x265).mkv" \
            "$DEST/Specials/${SERIES} S00E${ep_dest}.mkv"
done

# Koyomimonogatari 01-12 → S00E22-33
echo "  --- Koyomimonogatari ---"
for i in $(seq 1 12); do
    ep_src=$(printf "%02d" $i)
    ep_dest=$(printf "%02d" $((i + 21)))
    copy_ep "$SRC/03 Monogatari Final Season/03 Koyomimonogatari/[DB]Koyomimonogatari_-_${ep_src}_(10bit_BD1080p_x265).mkv" \
            "$DEST/Specials/${SERIES} S00E${ep_dest}.mkv"
done

# Owarimonogatari Second Season 01-07 → S00E35-41
echo "  --- Owarimonogatari Second Season ---"
for i in $(seq 1 7); do
    ep_src=$(printf "%02d" $i)
    ep_dest=$(printf "%02d" $((i + 34)))
    copy_ep "$SRC/03 Monogatari Final Season/04 Owarimonogatari Second Season/[DB]Owarimonogatari Second Season_-_${ep_src}_(10bit_BD1080p_x265).mkv" \
            "$DEST/Specials/${SERIES} S00E${ep_dest}.mkv"
done

# Zoku Owarimonogatari 01-06 → S00E42-47
echo "  --- Zoku Owarimonogatari ---"
for i in $(seq 1 6); do
    ep_src=$(printf "%02d" $i)
    ep_dest=$(printf "%02d" $((i + 41)))
    copy_ep "$SRC/03 Monogatari Final Season/05 Zoku Owarimonogatari/[DB]Zoku Owarimonogatari_-_${ep_src}_(10bit_BD1080p_x265).mkv" \
            "$DEST/Specials/${SERIES} S00E${ep_dest}.mkv"
done

echo ""
echo "=== Kizumonogatari (3 movies — kept separate) ==="
# Kizumonogatari are separate movies on TMDB, not part of the TV series.
# Copying into a "Kizumonogatari" subfolder within the series for now.
if $DRY_RUN; then
    echo "WOULD CREATE: $DEST/Kizumonogatari/"
else
    mkdir -p "$DEST/Kizumonogatari"
fi
for i in 1 2 3; do
    ep=$(printf "%02d" $i)
    copy_ep "$SRC/Kizumonogatari/[DB]Kizumonogatari_-_${ep}_(10bit_BD1080p_x265).mkv" \
            "$DEST/Kizumonogatari/Kizumonogatari Part ${i}.mkv"
done

echo ""
echo "================================"
echo "Total episodes processed: $TOTAL"
echo "Errors: $ERRORS"

if $DRY_RUN; then
    echo ""
    echo "This was a dry run. Run without --dry-run to copy files."
fi
