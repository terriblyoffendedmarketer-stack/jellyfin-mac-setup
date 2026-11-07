#!/bin/bash
# Syncs Jellyfin library to library.json and regenerates film-library.html
# Run on whichever device has Jellyfin active (Mac or phone)
# Usage: ./sync-library.sh [--push]
#   --push: commit and push to GitHub after syncing
# Silently exits if Jellyfin is not running (safe for cron/LaunchAgent)
# Always keeps the hard-drive films in the list, even in travel mode (drive unplugged) or if Jellyfin
# returns none of them; laptop+drive duplicates are merged into one entry with "locations".

# Ensure tools are on PATH (LaunchAgents run with a bare environment)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

JELLYFIN_URL="${JELLYFIN_URL:-http://localhost:8096}"
JELLYFIN_USER="${JELLYFIN_USER:-pjdruck}"
JELLYFIN_PASS="${JELLYFIN_PASS:-8544}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBRARY_JSON="$SCRIPT_DIR/library.json"
LIBRARY_PREV="$SCRIPT_DIR/.library-prev.json"
COMMENTS_JSON="$SCRIPT_DIR/film_comments.json"
HTML_FILE="$SCRIPT_DIR/film-library.html"
SWAP_URL_FILE="$SCRIPT_DIR/.calendar-swap-url"
PUSH=false

for arg in "$@"; do
    case "$arg" in
        --push) PUSH=true ;;
    esac
done

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1"; }

# If Jellyfin isn't running, exit silently (not an error)
if ! curl -sf "$JELLYFIN_URL/System/Ping" > /dev/null 2>&1; then
    log "Jellyfin not running — skipping sync"
    exit 0
fi

log "=== Jellyfin Library Sync ==="

# Authenticate
log "Authenticating..."
AUTH_RESPONSE=$(curl -sf "$JELLYFIN_URL/Users/authenticatebyname" \
    -H "Content-Type: application/json" \
    -H "X-Emby-Authorization: MediaBrowser Client=\"SyncScript\", Device=\"CLI\", DeviceId=\"sync-script\", Version=\"1.0\"" \
    -d "{\"Username\":\"$JELLYFIN_USER\",\"Pw\":\"$JELLYFIN_PASS\"}" 2>/dev/null)

if [ -z "$AUTH_RESPONSE" ]; then
    log "Error: Failed to authenticate with Jellyfin"
    exit 1
fi

USER_ID=$(echo "$AUTH_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['User']['Id'])" 2>/dev/null)
ACCESS_TOKEN=$(echo "$AUTH_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessToken'])" 2>/dev/null)

if [ -z "$USER_ID" ] || [ -z "$ACCESS_TOKEN" ]; then
    log "Error: Could not parse authentication response"
    exit 1
fi
log "Authenticated as $JELLYFIN_USER"

# Fetch library
log "Fetching library..."
RAW_ITEMS=$(curl -sf "$JELLYFIN_URL/Users/$USER_ID/Items?Recursive=true&IncludeItemTypes=Movie,Series&Fields=Path,Genres,CommunityRating,ProductionYear,Overview&SortBy=SortName&SortOrder=Ascending&Limit=10000" \
    -H "X-Emby-Token: $ACCESS_TOKEN" 2>/dev/null)

if [ -z "$RAW_ITEMS" ]; then
    log "Error: Failed to fetch library items"
    exit 1
fi
log "Library fetched"

# Build library.json
log "Building library.json..."
python3 << 'PYEOF' - "$RAW_ITEMS" "$LIBRARY_JSON"
import json, os, sys

# The list must ALWAYS include the hard-drive films, whatever mode Jellyfin is in:
# - travel mode (drive unplugged / travel config): Jellyfin only knows ~/Movies, so keep the last known drive films
# - drive plugged in but Jellyfin returns no drive films (e.g. the Movies library went missing, Oct 2026): keep them too
# Films found in more than one place (laptop + drive) are listed once with all locations.
DRIVE = "/Volumes/Backup Plus"
raw = json.loads(sys.argv[1])
output_path = sys.argv[2]
items = raw.get("Items", [])

def loc(path):
    return "drive" if path.startswith(DRIVE + "/") else "laptop"

fresh = [{
    "name": i.get("Name", ""), "year": i.get("ProductionYear"), "type": i.get("Type", ""),
    "genres": i.get("Genres", []), "rating": i.get("CommunityRating"), "path": i.get("Path", ""),
    "jellyfin_id": i.get("Id", ""), "location": loc(i.get("Path", "")),
} for i in items]

prev = []
if os.path.exists(output_path):
    try:
        prev = json.load(open(output_path)).get("items", [])
    except Exception:
        prev = []

drive_online = os.path.isdir(DRIVE + "/All Movies")
fresh_drive = sum(1 for e in fresh if e["location"] == "drive")
kept = []
if not drive_online or fresh_drive == 0:
    seen = {e["path"] for e in fresh}
    for e in prev:
        for path in e.get("paths", [e.get("path", "")]):
            if path.startswith(DRIVE + "/") and path not in seen:
                k = dict(e); k["path"] = path; k["location"] = "drive"; k.pop("paths", None); k.pop("locations", None)
                kept.append(k); seen.add(path)
    why = "drive not mounted" if not drive_online else "Jellyfin returned no drive films"
    print(f"Kept {len(kept)} last-known drive items ({why})")

merged = {}
for e in fresh + kept:
    key = (e["name"].strip().lower(), e["year"], e["type"])
    if key not in merged:
        m = dict(e); m["locations"] = [e["location"]]; m["paths"] = [e["path"]]
        merged[key] = m
    else:
        m = merged[key]
        if e["path"] not in m["paths"]:
            m["paths"].append(e["path"])
        if e["location"] not in m["locations"]:
            m["locations"].append(e["location"])
        if e["location"] == "drive":
            m["path"] = e["path"]   # the drive copy is the canonical one
out = sorted(merged.values(), key=lambda e: e["name"].lower())
for m in out:
    m.pop("location", None)

library = {
    "synced_at": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "drive_online": drive_online,
    "total_count": len(out),
    "items": out,
}
with open(output_path, "w") as f:
    json.dump(library, f, indent=2, ensure_ascii=False)
print(f"Wrote {len(out)} items to {output_path} ({len(fresh)} from Jellyfin, {len(kept)} kept from the drive)")
PYEOF

# Sync poster artwork
log "Syncing poster artwork..."
POSTERS_DIR="$SCRIPT_DIR/posters"
mkdir -p "$POSTERS_DIR"
python3 << 'PYEOF' - "$LIBRARY_JSON" "$POSTERS_DIR" "$JELLYFIN_URL" "$ACCESS_TOKEN"
import json, os, sys, urllib.request

library_path = sys.argv[1]
posters_dir = sys.argv[2]
jellyfin_url = sys.argv[3]
token = sys.argv[4]

with open(library_path) as f:
    items = json.load(f).get("items", [])

downloaded = 0
for item in items:
    jid = item.get("jellyfin_id")
    if not jid:
        continue
    dest = os.path.join(posters_dir, f"{jid}.jpg")
    if os.path.exists(dest):
        continue
    url = f"{jellyfin_url}/Items/{jid}/Images/Primary?maxWidth=280&quality=75"
    req = urllib.request.Request(url, headers={"X-Emby-Token": token})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            with open(dest, "wb") as out_f:
                out_f.write(resp.read())
        downloaded += 1
    except Exception:
        pass

if downloaded > 0:
    print(f"Downloaded {downloaded} new poster(s)")
PYEOF

# Generate HTML
log "Generating HTML..."
python3 << 'PYEOF' - "$LIBRARY_JSON" "$COMMENTS_JSON" "$HTML_FILE"
import json, sys, html, re
from pathlib import Path

library_path = sys.argv[1]
comments_path = sys.argv[2]
html_path = sys.argv[3]

with open(library_path) as f:
    library = json.load(f)

comments = {}
if Path(comments_path).exists():
    with open(comments_path) as f:
        comments = json.load(f)

def normalize_title(t):
    t = re.sub(r'\[.*?\]|\(.*?\)', '', t)
    t = re.sub(r'[^a-zA-Z0-9\s]', '', t)
    return ' '.join(t.lower().split())

comment_title_map = {}
comment_lookup = {}
for category, films in comments.items():
    for title, comment in films.items():
        norm = normalize_title(title)
        if norm:
            comment_title_map[norm] = (category, title)
            comment_lookup[norm] = comment
        comment_lookup[title.lower()] = comment

category_map = {}
comments_categories = list(comments.keys())

for item in library["items"]:
    name = item["name"]
    year = item.get("year")
    display = f"{name} ({year})" if year else name
    genres = item.get("genres", [])
    path = item.get("path", "")

    norm_name = normalize_title(name)
    matched_category = None
    if norm_name in comment_title_map:
        matched_category = comment_title_map[norm_name][0]

    folder_category = None
    parts = path.split('/')
    if 'All Movies' in parts:
        idx = parts.index('All Movies')
        if idx + 1 < len(parts):
            folder_category = parts[idx + 1]

    if matched_category in [None, "Movies in General"] and folder_category and folder_category != "Movies in General":
        matched_category = folder_category
    elif not matched_category and folder_category:
        matched_category = folder_category

    if not matched_category:
        if any(g in ["Animation", "Anime"] for g in genres):
            matched_category = "Anime movies"
        elif any(g in genres for g in ["Bollywood", "Indian"]):
            matched_category = "Indian Films"
        else:
            matched_category = "Movies in General"

    if matched_category not in category_map:
        category_map[matched_category] = []

    comment = comment_lookup.get(norm_name, "")
    if not comment:
        comment = comment_lookup.get(name.lower(), "")
    if not comment:
        comment = comment_lookup.get(display.lower(), "")

    category_map[matched_category].append({
        "display": display,
        "name": name,
        "year": year,
        "rating": item.get("rating"),
        "jellyfin_id": item.get("jellyfin_id", ""),
        "comment": comment,
        "category": matched_category,
        "type": item.get("type", "Movie"),
    })

for cat in category_map:
    category_map[cat].sort(key=lambda x: x["display"].lower())

ordered_cats = []
for cat in comments_categories:
    if cat in category_map and cat not in ordered_cats:
        ordered_cats.append(cat)
for cat in sorted(category_map.keys()):
    if cat not in ordered_cats:
        ordered_cats.append(cat)

synced_at = library.get("synced_at", "unknown")
total = library.get("total_count", sum(len(v) for v in category_map.values()))

# Build Category Sections
sections = []
for i, cat in enumerate(ordered_cats):
    films = category_map[cat]
    count = len(films)
    open_class = " open" if i == 0 else ""
    film_items = []
    for film in films:
        escaped_name = html.escape(film["display"])
        film_items.append(f'                <li class="film-item">{escaped_name}</li>')
    films_html = "\n".join(film_items)
    escaped_cat = html.escape(cat)
    sections.append(f'''        <div class="category-section{open_class}" data-category="{escaped_cat}">
            <div class="category-header" onclick="toggleSection(this)">
                <div class="category-title-wrap">
                    <span class="category-name">{escaped_cat}</span>
                    <span class="category-count">{count}</span>
                </div>
                <span class="toggle-icon">&#x25BC;</span>
            </div>
            <ul class="film-list">
{films_html}
            </ul>
        </div>''')

sections_html = "\n\n".join(sections)

# Build Gallery Cards (All films alphabetically)
all_films = sorted(
    [film for cat_films in category_map.values() for film in cat_films],
    key=lambda x: x["name"].lower()
)

gallery_cards = []
for film in all_films:
    name = film["name"]
    year = film.get("year")
    rating = film.get("rating")
    rating_str = f"{rating:.1f}" if rating else ""
    rating_badge = f'<span class="rating-badge">&#9733; {rating_str}</span>' if rating_str else ''
    display = film["display"]
    escaped_display = html.escape(display)
    escaped_name = html.escape(name)
    escaped_year = html.escape(str(year)) if year else ""
    jid = film.get("jellyfin_id", "")
    cat = film["category"]
    escaped_cat = html.escape(cat)
    norm_name = html.escape(name.lower())

    gallery_cards.append(f'''        <div class="film-card" data-title="{norm_name}" data-year="{escaped_year}" data-category="{escaped_cat}">
            <div class="poster-container">
                <img class="poster-img" src="posters/{jid}.jpg" alt="{escaped_display}" loading="lazy" onerror="this.style.display=\'none\'; this.nextElementSibling.style.display=\'flex\';">
                <div class="poster-fallback" style="display:none;">
                    <span class="fallback-icon">&#127916;</span>
                    <span class="fallback-title">{escaped_name}</span>
                </div>
                {rating_badge}
            </div>
            <div class="card-details">
                <div class="card-title" title="{escaped_display}">{escaped_name}</div>
                <div class="card-meta">
                    <span class="card-year">{escaped_year}</span>
                    <span class="card-category" title="{escaped_cat}">{escaped_cat}</span>
                </div>
            </div>
        </div>''')

gallery_html = "\n".join(gallery_cards)

options = ['            <option value="all">All Categories</option>']
for cat in ordered_cats:
    count = len(category_map[cat])
    escaped_cat = html.escape(cat)
    options.append(f'            <option value="{escaped_cat}">{escaped_cat} ({count})</option>')
options_html = "\n".join(options)

page = f'''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="theme-color" content="#0f172a">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <link rel="manifest" href="manifest.json">
    <link rel="icon" href="icon.svg" type="image/svg+xml">
    <title>Film Library ({total} Films)</title>
    <style>
        :root {{
            --bg-color: #0f172a;
            --card-bg: #1e293b;
            --text-primary: #f8fafc;
            --text-secondary: #94a3b8;
            --accent: #38bdf8;
            --accent-gradient: linear-gradient(135deg, #38bdf8 0%, #818cf8 100%);
            --badge-bg: #334155;
            --border-color: #334155;
            --hover-bg: #2563eb;
        }}

        [data-theme="light"] {{
            --bg-color: #f1f5f9;
            --card-bg: #ffffff;
            --text-primary: #0f172a;
            --text-secondary: #64748b;
            --accent: #0284c7;
            --accent-gradient: linear-gradient(135deg, #0284c7 0%, #4f46e5 100%);
            --badge-bg: #e2e8f0;
            --border-color: #cbd5e1;
            --hover-bg: #2563eb;
        }}

        * {{
            box-sizing: border-box;
            margin: 0;
            padding: 0;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            transition: background-color 0.3s ease, color 0.3s ease;
        }}

        body {{
            background-color: var(--bg-color);
            color: var(--text-primary);
            padding: 1rem;
            line-height: 1.5;
        }}

        .container {{
            max-width: 1200px;
            margin: 0 auto;
            padding-bottom: 3rem;
        }}

        header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 1.5rem;
            background: var(--card-bg);
            padding: 1.25rem;
            border-radius: 12px;
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
            border: 1px solid var(--border-color);
        }}

        h1 {{
            font-size: 1.25rem;
            font-weight: 700;
            background: var(--accent-gradient);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }}

        .subtitle {{
            font-size: 0.85rem;
            color: var(--text-secondary);
        }}

        .synced-at {{
            font-size: 0.75rem;
            color: var(--text-secondary);
            margin-top: 0.25rem;
        }}

        .theme-toggle {{
            background: var(--badge-bg);
            border: none;
            color: var(--text-primary);
            padding: 0.5rem 0.75rem;
            border-radius: 8px;
            cursor: pointer;
            font-size: 0.85rem;
            font-weight: 600;
        }}

        .theme-toggle:active {{
            transform: scale(0.95);
        }}

        .search-filter-container {{
            display: flex;
            flex-direction: column;
            gap: 0.75rem;
            margin-bottom: 1rem;
        }}

        @media (min-width: 600px) {{
            .search-filter-container {{
                flex-direction: row;
            }}
        }}

        .search-box {{
            flex: 1;
            position: relative;
        }}

        .search-box input {{
            width: 100%;
            padding: 0.75rem 1rem 0.75rem 2.5rem;
            border-radius: 8px;
            border: 1px solid var(--border-color);
            background-color: var(--card-bg);
            color: var(--text-primary);
            font-size: 0.95rem;
            outline: none;
        }}

        .search-box input:focus {{
            border-color: var(--accent);
        }}

        .search-icon {{
            position: absolute;
            left: 0.85rem;
            top: 50%;
            transform: translateY(-50%);
            color: var(--text-secondary);
            font-size: 0.95rem;
        }}

        .category-filter {{
            padding: 0.75rem 1rem;
            border-radius: 8px;
            border: 1px solid var(--border-color);
            background-color: var(--card-bg);
            color: var(--text-primary);
            font-size: 0.95rem;
            outline: none;
            cursor: pointer;
        }}

        /* View Switcher Controls */
        .controls-bar {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 1.25rem;
            flex-wrap: wrap;
            gap: 0.75rem;
        }}

        .view-switcher {{
            display: inline-flex;
            background: var(--card-bg);
            padding: 0.3rem;
            border-radius: 10px;
            border: 1px solid var(--border-color);
            gap: 0.25rem;
        }}

        .view-btn {{
            display: inline-flex;
            align-items: center;
            gap: 0.5rem;
            background: transparent;
            border: none;
            color: var(--text-secondary);
            padding: 0.5rem 0.9rem;
            border-radius: 8px;
            font-size: 0.88rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s ease;
        }}

        .view-btn:hover {{
            color: var(--text-primary);
        }}

        .view-btn.active {{
            background: var(--hover-bg);
            color: #ffffff;
            box-shadow: 0 2px 6px rgba(37, 99, 235, 0.35);
        }}

        .films-counter {{
            font-size: 0.85rem;
            color: var(--text-secondary);
            font-weight: 500;
        }}

        /* Gallery Grid */
        .gallery-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(135px, 1fr));
            gap: 1.25rem 0.9rem;
            margin-bottom: 2rem;
        }}

        @media (min-width: 500px) {{
            .gallery-grid {{
                grid-template-columns: repeat(auto-fill, minmax(155px, 1fr));
                gap: 1.5rem 1rem;
            }}
        }}

        @media (min-width: 768px) {{
            .gallery-grid {{
                grid-template-columns: repeat(auto-fill, minmax(175px, 1fr));
                gap: 1.75rem 1.25rem;
            }}
        }}

        @media (min-width: 1024px) {{
            .gallery-grid {{
                grid-template-columns: repeat(auto-fill, minmax(190px, 1fr));
                gap: 2rem 1.4rem;
            }}
        }}

        .film-card {{
            background: var(--card-bg);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            overflow: hidden;
            display: flex;
            flex-direction: column;
            transition: transform 0.2s ease, box-shadow 0.2s ease, border-color 0.2s ease;
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
        }}

        .film-card:hover {{
            transform: translateY(-4px);
            box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.25);
            border-color: var(--accent);
        }}

        .poster-container {{
            position: relative;
            width: 100%;
            aspect-ratio: 2 / 3;
            background: #0b0f19;
            overflow: hidden;
        }}

        .poster-img {{
            width: 100%;
            height: 100%;
            object-fit: cover;
            display: block;
            transition: transform 0.3s ease;
        }}

        .film-card:hover .poster-img {{
            transform: scale(1.03);
        }}

        .poster-fallback {{
            width: 100%;
            height: 100%;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%);
            padding: 1rem;
            text-align: center;
            gap: 0.5rem;
        }}

        .fallback-icon {{
            font-size: 2rem;
            opacity: 0.6;
        }}

        .fallback-title {{
            font-size: 0.8rem;
            color: var(--text-secondary);
            font-weight: 500;
            line-height: 1.3;
        }}

        .rating-badge {{
            position: absolute;
            top: 0.5rem;
            right: 0.5rem;
            background: rgba(15, 23, 42, 0.85);
            backdrop-filter: blur(4px);
            color: #fbbf24;
            font-size: 0.72rem;
            font-weight: 700;
            padding: 0.2rem 0.45rem;
            border-radius: 6px;
            border: 1px solid rgba(255, 255, 255, 0.1);
            display: flex;
            align-items: center;
            gap: 0.25rem;
        }}

        .card-details {{
            padding: 0.75rem 0.85rem;
            display: flex;
            flex-direction: column;
            gap: 0.35rem;
            flex: 1;
            justify-content: space-between;
        }}

        .card-title {{
            font-size: 0.92rem;
            font-weight: 600;
            color: var(--text-primary);
            line-height: 1.35;
            display: -webkit-box;
            -webkit-line-clamp: 2;
            -webkit-box-orient: vertical;
            overflow: hidden;
            word-break: break-word;
        }}

        .card-meta {{
            display: flex;
            align-items: center;
            justify-content: space-between;
            font-size: 0.75rem;
            color: var(--text-secondary);
            gap: 0.5rem;
        }}

        .card-year {{
            font-weight: 600;
            color: var(--accent);
        }}

        .card-category {{
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
            background: var(--badge-bg);
            padding: 0.15rem 0.45rem;
            border-radius: 4px;
            font-size: 0.7rem;
            max-width: 65%;
        }}

        /* Category Accordions View */
        .category-section {{
            background-color: var(--card-bg);
            border-radius: 12px;
            border: 1px solid var(--border-color);
            margin-bottom: 1rem;
            overflow: hidden;
            box-shadow: 0 2px 4px rgba(0,0,0,0.05);
        }}

        .category-header {{
            padding: 1rem 1.25rem;
            display: flex;
            justify-content: space-between;
            align-items: center;
            cursor: pointer;
            background-color: var(--card-bg);
            user-select: none;
        }}

        .category-header:hover {{
            background-color: rgba(100, 116, 139, 0.05);
        }}

        .category-title-wrap {{
            display: flex;
            align-items: center;
            gap: 0.75rem;
        }}

        .category-name {{
            font-size: 1.05rem;
            font-weight: 600;
        }}

        .category-count {{
            background-color: var(--badge-bg);
            color: var(--text-secondary);
            font-size: 0.75rem;
            padding: 0.2rem 0.5rem;
            border-radius: 999px;
            font-weight: 600;
        }}

        .toggle-icon {{
            color: var(--text-secondary);
            font-size: 0.85rem;
            transition: transform 0.2s ease;
        }}

        .category-section.open .toggle-icon {{
            transform: rotate(180deg);
        }}

        .film-list {{
            display: none;
            padding: 0 1.25rem 1.25rem 1.25rem;
            list-style: none;
            border-top: 1px solid var(--border-color);
            animation: fadeIn 0.2s ease-in-out;
        }}

        .category-section.open .film-list {{
            display: block;
        }}

        .film-item {{
            padding: 0.5rem 0;
            border-bottom: 1px solid var(--border-color);
            font-size: 0.95rem;
            color: var(--text-primary);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }}

        .film-item:last-child {{
            border-bottom: none;
        }}

        .no-results {{
            text-align: center;
            padding: 3rem 1rem;
            color: var(--text-secondary);
            display: none;
        }}

        @keyframes fadeIn {{
            from {{ opacity: 0; transform: translateY(-4px); }}
            to {{ opacity: 1; transform: translateY(0); }}
        }}
    </style>
</head>
<body data-theme="dark">

<div class="container">
    <header>
        <div>
            <h1>Film Library</h1>
            <div class="subtitle">{total} films across {len(ordered_cats)} categories</div>
            <div class="synced-at">Last synced: {synced_at}</div>
        </div>
        <button class="theme-toggle" id="themeToggleBtn" onclick="toggleTheme()">Light</button>
    </header>

    <div class="search-filter-container">
        <div class="search-box">
            <span class="search-icon">&#x1F50D;</span>
            <input type="text" id="searchInput" placeholder="Search films by title or year..." oninput="filterFilms()">
        </div>
        <select class="category-filter" id="categoryFilter" onchange="filterByCategory()">
{options_html}
        </select>
    </div>

    <div class="controls-bar">
        <div class="view-switcher" role="tablist">
            <button class="view-btn active" id="btnGalleryView" onclick="switchView('gallery')" role="tab" aria-selected="true">
                <svg width="15" height="15" viewBox="0 0 24 24" fill="currentColor"><path d="M4 4h4v4H4zm6 0h4v4h-4zm6 0h4v4h-4zM4 10h4v4H4zm6 0h4v4h-4zm6 0h4v4h-4zM4 16h4v4H4zm6 0h4v4h-4zm6 0h4v4h-4z"/></svg>
                Poster Gallery
            </button>
            <button class="view-btn" id="btnCategoryView" onclick="switchView('categories')" role="tab" aria-selected="false">
                <svg width="15" height="15" viewBox="0 0 24 24" fill="currentColor"><path d="M3 13h2v-2H3v2zm0 4h2v-2H3v2zm0-8h2V7H3v2zm4 4h14v-2H7v2zm0 4h14v-2H7v2zM7 7v2h14V7H7z"/></svg>
                Categories
            </button>
        </div>
        <div class="films-counter" id="filmsCounter">{total} films</div>
    </div>

    <div id="galleryContainer" class="gallery-grid">
{gallery_html}
    </div>

    <div id="filmContainer" style="display: none;">
{sections_html}
    </div>

    <div id="noResults" class="no-results">No films found matching your search.</div>
</div>

<script>
    function toggleSection(header) {{
        const section = header.parentElement;
        section.classList.toggle('open');
    }}

    function toggleTheme() {{
        const body = document.body;
        const btn = document.getElementById('themeToggleBtn');
        if (body.getAttribute('data-theme') === 'dark') {{
            body.setAttribute('data-theme', 'light');
            btn.textContent = 'Dark';
        }} else {{
            body.setAttribute('data-theme', 'dark');
            btn.textContent = 'Light';
        }}
    }}

    function switchView(view) {{
        const galleryEl = document.getElementById('galleryContainer');
        const catEl = document.getElementById('filmContainer');
        const btnGallery = document.getElementById('btnGalleryView');
        const btnCat = document.getElementById('btnCategoryView');

        if (view === 'categories') {{
            galleryEl.style.display = 'none';
            catEl.style.display = 'block';
            btnGallery.classList.remove('active');
            btnGallery.setAttribute('aria-selected', 'false');
            btnCat.classList.add('active');
            btnCat.setAttribute('aria-selected', 'true');
        }} else {{
            galleryEl.style.display = 'grid';
            catEl.style.display = 'none';
            btnGallery.classList.add('active');
            btnGallery.setAttribute('aria-selected', 'true');
            btnCat.classList.remove('active');
            btnCat.setAttribute('aria-selected', 'false');
        }}

        try {{
            localStorage.setItem('preferredView', view);
        }} catch (e) {{}}

        filterFilms();
    }}

    function filterFilms() {{
        const query = document.getElementById('searchInput').value.toLowerCase().trim();
        const selectedCategory = document.getElementById('categoryFilter').value;
        const isGallery = document.getElementById('btnGalleryView').classList.contains('active');
        let totalVisible = 0;

        if (isGallery) {{
            const cards = document.querySelectorAll('.film-card');
            cards.forEach(card => {{
                const title = card.getAttribute('data-title') || '';
                const year = card.getAttribute('data-year') || '';
                const cat = card.getAttribute('data-category') || '';

                const matchCat = (selectedCategory === 'all' || cat === selectedCategory);
                const matchQuery = !query || title.includes(query) || year.includes(query) || cat.toLowerCase().includes(query);

                if (matchCat && matchQuery) {{
                    card.style.display = 'flex';
                    totalVisible++;
                }} else {{
                    card.style.display = 'none';
                }}
            }});
        }} else {{
            const sections = document.querySelectorAll('.category-section');
            sections.forEach(section => {{
                const categoryName = section.getAttribute('data-category');
                const matchCat = (selectedCategory === 'all' || categoryName === selectedCategory);

                if (!matchCat) {{
                    section.style.display = 'none';
                    return;
                }}

                const items = section.querySelectorAll('.film-item');
                let sectionHasMatch = false;

                items.forEach(item => {{
                    const text = item.textContent.toLowerCase();
                    if (!query || text.includes(query)) {{
                        item.style.display = 'flex';
                        sectionHasMatch = true;
                        totalVisible++;
                    }} else {{
                        item.style.display = 'none';
                    }}
                }});

                if (!query) {{
                    section.style.display = matchCat ? 'block' : 'none';
                }} else {{
                    section.style.display = sectionHasMatch ? 'block' : 'none';
                    if (sectionHasMatch) {{
                        section.classList.add('open');
                    }}
                }}
            }});
        }}

        const noResults = document.getElementById('noResults');
        if (noResults) {{
            noResults.style.display = totalVisible === 0 ? 'block' : 'none';
        }}

        const counter = document.getElementById('filmsCounter');
        if (counter) {{
            counter.textContent = `${{totalVisible}} film${{totalVisible === 1 ? '' : 's'}}`;
        }}
    }}

    function filterByCategory() {{
        filterFilms();
    }}

    // Default to gallery view or restore saved preference
    const savedView = (function() {{
        try {{ return localStorage.getItem('preferredView') || 'gallery'; }}
        catch (e) {{ return 'gallery'; }}
    }})();
    switchView(savedView);

    if ('serviceWorker' in navigator) {{
        navigator.serviceWorker.register('sw.js');
    }}
</script>

</body>
</html>'''

with open(html_path, "w") as f:
    f.write(page)

print(f"Generated {html_path} with {total} films in {len(ordered_cats)} categories and {len(all_films)} gallery cards")
PYEOF

# Detect new films and trigger calendar swap
if [ -f "$SWAP_URL_FILE" ] && [ -f "$LIBRARY_PREV" ]; then
    log "Checking for new films..."
    NEW_FILMS=$(python3 << 'PYEOF' - "$LIBRARY_PREV" "$LIBRARY_JSON"
import json, sys

prev_path = sys.argv[1]
curr_path = sys.argv[2]

with open(prev_path) as f:
    prev = {item["name"].lower() for item in json.load(f).get("items", [])}

with open(curr_path) as f:
    curr_items = json.load(f).get("items", [])

new_films = []
for item in curr_items:
    if item["name"].lower() not in prev:
        genres = ", ".join(item.get("genres", []))
        rating = item.get("rating")
        desc_parts = []
        if genres:
            desc_parts.append(f"Genre: {genres}")
        if rating:
            desc_parts.append(f"Rating: {rating}/10")
        title = item["name"]
        if item.get("year"):
            title = f"{item['name']} ({item['year']})"
        new_films.append({"title": title, "description": "\n".join(desc_parts)})

print(json.dumps(new_films))
PYEOF
    )

    FILM_COUNT=$(echo "$NEW_FILMS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

    if [ "$FILM_COUNT" -gt 0 ]; then
        SWAP_URL=$(cat "$SWAP_URL_FILE")
        log "Found $FILM_COUNT new films — calling calendar swap..."
        SWAP_RESULT=$(curl -sL \
            -H "Content-Type: application/json" \
            -d "{\"films\": $NEW_FILMS}" \
            "$SWAP_URL" 2>/dev/null)
        log "Calendar swap result: $SWAP_RESULT"
    else
        log "No new films detected"
    fi
fi
cp "$LIBRARY_JSON" "$LIBRARY_PREV"

if $PUSH; then
    log "Pushing to GitHub..."
    cd "$SCRIPT_DIR"
    git pull --rebase origin master 2>/dev/null || true
    git add library.json film-library.html sw.js posters/
    if git diff --cached --quiet; then
        log "No changes to push"
    else
        git commit -m "Update film library ($(date +%Y-%m-%d))"
        git push origin master 2>&1 || log "Warning: git push failed — check credentials"
    fi
    log "Done. Library synced and pushed."
else
    log "Done. Run with --push to commit and push to GitHub."
fi
