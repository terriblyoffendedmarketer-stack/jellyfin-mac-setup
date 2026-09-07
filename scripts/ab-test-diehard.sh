#!/bin/bash
# ab-test-diehard.sh — Extract Die Hard scenes with different compression levels
# Creates video clips for A/B testing on Jellyfin
#
# Output: /Volumes/Backup Plus/All Movies/Audio Tests/
#   Each scene gets 4 versions (A/B/C/D) with video + processed audio
#
# Usage: bash scripts/ab-test-diehard.sh

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SRC="/Volumes/Backup Plus/All Movies/Movies in General/Die Hard (1988)/Die.Hard.BluRay.1080p.x264.5.1.Judas.mp4"
OUTDIR="/Volumes/Backup Plus/All Movies/Audio Tests"

# A: Raw downmix — no compression, just 5.1→stereo (what Jellyfin does live)
A_FILTER="pan=stereo|FL=0.707*FC+0.707*FL+0.5*BL+0.25*LFE|FR=0.707*FC+0.707*FR+0.5*BR+0.25*LFE"

# B: Current settings (what's already on Die Hard) — gentle compression
B_FILTER="pan=stereo|FL=1.0*FC+0.707*FL+0.5*BL+0.25*LFE|FR=1.0*FC+0.707*FR+0.5*BR+0.25*LFE,acompressor=threshold=0.089:ratio=4:attack=5:release=100:makeup=5:knee=6,loudnorm=I=-16:TP=-1.5:LRA=11"

# C: Medium — stronger compression + centre boost
C_FILTER="pan=stereo|FL=1.0*FC+0.707*FL+0.5*BL+0.25*LFE|FR=1.0*FC+0.707*FR+0.5*BR+0.25*LFE,acompressor=threshold=0.031:ratio=6:attack=5:release=150:makeup=6:knee=7,loudnorm=I=-16:TP=-1.5:LRA=9"

# D: Aggressive — heavy compression, tight loudness range
D_FILTER="pan=stereo|FL=1.0*FC+0.707*FL+0.5*BL+0.25*LFE|FR=1.0*FC+0.707*FR+0.5*BR+0.25*LFE,acompressor=threshold=0.01:ratio=8:attack=5:release=200:makeup=8:knee=8,loudnorm=I=-16:TP=-1.5:LRA=7"

FILTERS=("$A_FILTER" "$B_FILTER" "$C_FILTER" "$D_FILTER")
LABELS=("A_original" "B_current" "C_medium" "D_aggressive")
DESCS=("no compression" "gentle (current)" "medium" "aggressive")

# Scenes: name|start|duration
declare -a SCENES=(
    "1_Fists_With_Feet|00:19:10|40"
    "2_Hostage_Takeover|00:31:50|45"
    "3_Under_Table_Whisper|00:51:50|40"
    "4_Roof_Explosion|01:03:50|45"
    "5_Big_Action|01:31:50|45"
    "6_Final_Confrontation|01:54:50|45"
)

mkdir -p "$OUTDIR"

echo "Creating A/B test clips from Die Hard (1988)"
echo "Output: $OUTDIR"
echo "6 scenes x 4 compression levels = 24 clips"
echo "================================================"

TOTAL=0
FAILED=0

for scene_data in "${SCENES[@]}"; do
    IFS='|' read -r name start dur <<< "$scene_data"
    echo ""
    echo "--- Scene $name (${start}, ${dur}s) ---"

    for i in 0 1 2 3; do
        label="${LABELS[$i]}"
        desc="${DESCS[$i]}"
        filter="${FILTERS[$i]}"
        outfile="$OUTDIR/DieHard_${name}_${label}.mp4"

        echo -n "  ${label} (${desc})... "

        ffmpeg -y -hide_banner -loglevel warning \
            -ss "$start" -t "$dur" -i "$SRC" \
            -map 0:v:0 -map 0:a:0 \
            -c:v copy \
            -af "$filter" \
            -c:a aac -b:a 192k -ac 2 \
            "$outfile" 2>/dev/null

        if [ $? -eq 0 ] && [ -f "$outfile" ]; then
            SIZE=$(du -h "$outfile" | cut -f1)
            echo "done (${SIZE})"
            TOTAL=$((TOTAL + 1))
        else
            echo "FAILED"
            FAILED=$((FAILED + 1))
        fi
    done
done

echo ""
echo "================================================"
echo "Created: $TOTAL clips  |  Failed: $FAILED"
echo "Location: $OUTDIR"
echo ""
echo "HOW TO TEST:"
echo "  1. Start Jellyfin, scan library (Audio Tests will appear)"
echo "  2. For each scene, play A → B → C → D back to back"
echo "  3. Keep your volume at a FIXED level — don't touch it between clips"
echo ""
echo "WHAT YOU'RE COMPARING:"
echo "  A = Raw downmix, no compression (the old experience)"
echo "  B = Gentle compression (what's on Die Hard right now — you said 'miles better')"
echo "  C = Medium compression (more even volume)"
echo "  D = Aggressive compression (flattest volume, may sound unnatural)"
echo ""
echo "Pick the letter that sounds best to you on your soundbar."
