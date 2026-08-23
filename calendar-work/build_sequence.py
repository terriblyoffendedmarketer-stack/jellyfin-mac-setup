import json
import random
from datetime import datetime, timedelta
from collections import defaultdict

random.seed(42)

with open('/home/user/jellyfin-mac-setup/library.json') as f:
    library = json.load(f)

with open('/home/user/jellyfin-mac-setup/film_comments.json') as f:
    comments = json.load(f)

items = library['items']

# Build a comment lookup by film name (approximate matching)
comment_lookup = {}
for category, films in comments.items():
    for film_key, comment in films.items():
        # Normalize: strip year, path artifacts
        clean = film_key.strip()
        comment_lookup[clean] = {'comment': comment, 'category': category}

def find_comment(name, path):
    """Find a comment for a film, trying multiple matching strategies."""
    # Direct name match
    for key, val in comment_lookup.items():
        if name.lower() in key.lower() or key.lower() in name.lower():
            return val
    # Path-based match
    for key, val in comment_lookup.items():
        key_clean = key.split('(')[0].strip().lower()
        if key_clean and key_clean in path.lower():
            return val
    return None

# Classify films into vibe categories for sequencing
def classify_vibe(item):
    """Classify a film into a 'vibe' bucket for better sequencing."""
    name = item['name']
    genres = [g.lower() for g in (item.get('genres') or [])]
    path = item.get('path', '')
    rating = item.get('rating') or 0

    # Directory-based classifications
    if '/Andrei Tarkovsky/' in path:
        return 'contemplative'
    if '/Hong Sang Soo/' in path:
        return 'contemplative'

    # Genre-based classifications
    genre_set = set(genres)

    # Fun/High-energy
    if genre_set & {'comedy'} and genre_set & {'action', 'adventure', 'crime'}:
        return 'fun'
    if 'animation' in genre_set and item['type'] != 'Series':
        return 'anime_fun'
    if 'animation' in genre_set and item['type'] == 'Series':
        return 'anime_series'

    # Pure comedy
    if 'comedy' in genre_set and not genre_set & {'drama', 'crime', 'thriller', 'horror'}:
        return 'fun'

    # Action/Adventure (exciting)
    if genre_set & {'action'} and not genre_set & {'war', 'history'}:
        return 'action'

    # Romance/Feel-good
    if 'romance' in genre_set and not genre_set & {'thriller', 'horror', 'crime', 'war'}:
        return 'romance'

    # Horror/Dark
    if 'horror' in genre_set:
        return 'horror'

    # Sci-fi (usually engaging)
    if 'science fiction' in genre_set and not genre_set & {'horror'}:
        return 'scifi'

    # Thriller/Crime (engaging)
    if genre_set & {'thriller', 'crime', 'mystery'}:
        return 'thriller'

    # Comedy-drama (lighter side)
    if 'comedy' in genre_set and 'drama' in genre_set:
        return 'comedy_drama'

    # War/History (heavy but engaging)
    if genre_set & {'war', 'history'}:
        return 'epic'

    # Documentary
    if 'documentary' in genre_set:
        return 'documentary'

    # Adventure
    if 'adventure' in genre_set:
        return 'adventure'

    # Music
    if 'music' in genre_set:
        return 'fun'

    # Family/Fantasy
    if genre_set & {'family', 'fantasy'}:
        return 'fantasy'

    # Pure drama (heavier)
    if genres == ['drama']:
        return 'drama'

    # Drama with other light genres
    if 'drama' in genre_set:
        return 'drama'

    # TV Series
    if item['type'] == 'Series':
        return 'series'

    return 'drama'

# Categorize all films
vibe_buckets = defaultdict(list)
for item in items:
    vibe = classify_vibe(item)
    vibe_buckets[vibe].append(item)

# Print distribution
print("Vibe distribution:")
for vibe, films in sorted(vibe_buckets.items(), key=lambda x: -len(x[1])):
    print(f"  {vibe}: {len(films)}")

# Define which vibes are "light" vs "heavy"
light_vibes = {'fun', 'action', 'romance', 'anime_fun', 'comedy_drama', 'scifi', 'adventure', 'fantasy', 'anime_series'}
heavy_vibes = {'contemplative', 'drama', 'documentary', 'epic'}
medium_vibes = {'thriller', 'horror', 'series'}

# Shuffle within each bucket
for vibe in vibe_buckets:
    random.shuffle(vibe_buckets[vibe])

# Build the sequence using interleaving
# Strategy: After every heavy/medium film, try to place a light one
# Never more than 2 heavy films in a row
# Round-robin through vibe categories, but with weighting

# Create ordered pools
light_pool = []
heavy_pool = []
medium_pool = []

for vibe in light_vibes:
    light_pool.extend([(item, vibe) for item in vibe_buckets.get(vibe, [])])
for vibe in heavy_vibes:
    heavy_pool.extend([(item, vibe) for item in vibe_buckets.get(vibe, [])])
for vibe in medium_vibes:
    medium_pool.extend([(item, vibe) for item in vibe_buckets.get(vibe, [])])

random.shuffle(light_pool)
random.shuffle(heavy_pool)
random.shuffle(medium_pool)

print(f"\nLight: {len(light_pool)}, Medium: {len(medium_pool)}, Heavy: {len(heavy_pool)}")
print(f"Total: {len(light_pool) + len(medium_pool) + len(heavy_pool)}")

# Build sequence with pattern: L H L M L H L M ...
# Roughly: light, heavy, light, medium, light, heavy...
# This ensures joy is peppered in
sequence = []
li, hi, mi = 0, 0, 0
consecutive_heavy = 0

# Use a pattern-based approach
# Target ratio: ~40% light, ~35% heavy, ~25% medium
# Pattern repeats: L, H, L, M, L, H, L, M, H, L
pattern = ['light', 'heavy', 'light', 'medium', 'light', 'heavy', 'light', 'medium', 'heavy', 'light']
pattern_idx = 0

while li < len(light_pool) or hi < len(heavy_pool) or mi < len(medium_pool):
    target = pattern[pattern_idx % len(pattern)]
    pattern_idx += 1

    placed = False
    if target == 'light' and li < len(light_pool):
        sequence.append(light_pool[li])
        li += 1
        consecutive_heavy = 0
        placed = True
    elif target == 'heavy' and hi < len(heavy_pool):
        sequence.append(heavy_pool[hi])
        hi += 1
        consecutive_heavy += 1
        placed = True
    elif target == 'medium' and mi < len(medium_pool):
        sequence.append(medium_pool[mi])
        mi += 1
        consecutive_heavy = 0
        placed = True

    if not placed:
        # Fallback: take from any remaining pool
        if li < len(light_pool):
            sequence.append(light_pool[li])
            li += 1
            consecutive_heavy = 0
        elif mi < len(medium_pool):
            sequence.append(medium_pool[mi])
            mi += 1
            consecutive_heavy = 0
        elif hi < len(heavy_pool):
            sequence.append(heavy_pool[hi])
            hi += 1

# Verify no 3+ consecutive heavy films
runs = []
current_run = 0
for item, vibe in sequence:
    if vibe in heavy_vibes:
        current_run += 1
    else:
        if current_run > 0:
            runs.append(current_run)
        current_run = 0
if current_run > 0:
    runs.append(current_run)

max_heavy_run = max(runs) if runs else 0
print(f"\nMax consecutive heavy films: {max_heavy_run}")

# Post-process: break up any run of 3+ heavy films
final_sequence = list(sequence)
for _ in range(5):  # Multiple passes
    i = 0
    while i < len(final_sequence) - 2:
        vibes = [final_sequence[j][1] for j in range(i, min(i+3, len(final_sequence)))]
        if all(v in heavy_vibes for v in vibes):
            # Find nearest light film to swap with
            for j in range(i+3, len(final_sequence)):
                if final_sequence[j][1] in light_vibes:
                    final_sequence[i+1], final_sequence[j] = final_sequence[j], final_sequence[i+1]
                    break
        i += 1

# Re-verify
runs = []
current_run = 0
for item, vibe in final_sequence:
    if vibe in heavy_vibes:
        current_run += 1
    else:
        if current_run > 0:
            runs.append(current_run)
        current_run = 0
if current_run > 0:
    runs.append(current_run)
max_heavy_run = max(runs) if runs else 0
print(f"After fix - Max consecutive heavy films: {max_heavy_run}")

# Build calendar events
# Day 1 = Aug 23, 2026 = Hereditary (manual)
start_date = datetime(2026, 8, 23)

calendar_events = []

# Day 1: Hereditary
hereditary_comment = "You've been wanting to watch this. Ari Aster's debut feature — a family grief drama that turns into something much darker. The first hour is a slow burn about loss; the last act is pure dread. Toni Collette's performance alone is worth it."
calendar_events.append({
    'day': 1,
    'date': start_date.strftime('%Y-%m-%d'),
    'name': 'Hereditary',
    'year': 2018,
    'vibe': 'horror',
    'description': hereditary_comment
})

# Days 2 onwards: sequenced library
for idx, (item, vibe) in enumerate(final_sequence):
    day = idx + 2
    date = start_date + timedelta(days=day - 1)

    # Find comment
    comment_data = find_comment(item['name'], item.get('path', ''))

    year_str = ''
    if item.get('year') and isinstance(item['year'], int) and item['year'] < 9999:
        year_str = str(item['year'])

    genres = item.get('genres', [])
    genre_str = ', '.join(genres) if genres else ''

    # Build description
    desc_parts = []
    if comment_data:
        desc_parts.append(comment_data['comment'])
    if genre_str:
        desc_parts.append(f"Genres: {genre_str}")
    if item.get('rating'):
        desc_parts.append(f"Rating: {item['rating']}")
    desc_parts.append(f"Day {day} of {len(final_sequence) + 1}")

    description = '\n'.join(desc_parts)

    title = item['name']
    if year_str:
        title = f"{item['name']} ({year_str})"

    calendar_events.append({
        'day': day,
        'date': date.strftime('%Y-%m-%d'),
        'name': title,
        'year': year_str,
        'vibe': vibe,
        'description': description
    })

print(f"\nTotal calendar events: {len(calendar_events)}")
print(f"Date range: {calendar_events[0]['date']} to {calendar_events[-1]['date']}")

# Show first 14 days as sample
print("\nFirst 14 days:")
for e in calendar_events[:14]:
    print(f"  Day {e['day']:3d} | {e['date']} | [{e['vibe']:15s}] {e['name']}")

# Show a sample from the middle
print("\nDays 100-113:")
for e in calendar_events[99:113]:
    print(f"  Day {e['day']:3d} | {e['date']} | [{e['vibe']:15s}] {e['name']}")

# Save to file
with open('/tmp/claude-0/-home-user-jellyfin-mac-setup/ee98ec7d-d2ab-5739-b209-9eed5df7a038/scratchpad/calendar_events.json', 'w') as f:
    json.dump(calendar_events, f, indent=2)

print(f"\nSaved {len(calendar_events)} events to calendar_events.json")

# Vibe distribution in final sequence
from collections import Counter
vibe_counts = Counter(vibe for _, vibe in final_sequence)
print("\nFinal vibe distribution:")
for v, c in vibe_counts.most_common():
    label = 'LIGHT' if v in light_vibes else ('HEAVY' if v in heavy_vibes else 'MEDIUM')
    print(f"  {v:15s}: {c:3d} ({label})")
