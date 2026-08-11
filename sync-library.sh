#!/bin/bash
# Syncs Jellyfin library to library.json and regenerates film-library.html
# Run on whichever device has Jellyfin active (Mac or phone)
# Usage: ./sync-library.sh [--push]
#   --push: commit and push to GitHub after syncing

set -euo pipefail

JELLYFIN_URL="${JELLYFIN_URL:-http://localhost:8096}"
JELLYFIN_USER="${JELLYFIN_USER:-pjdruck}"
JELLYFIN_PASS="${JELLYFIN_PASS:-8544}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBRARY_JSON="$SCRIPT_DIR/library.json"
COMMENTS_JSON="$SCRIPT_DIR/film_comments.json"
HTML_FILE="$SCRIPT_DIR/film-library.html"
PUSH=false

for arg in "$@"; do
    case "$arg" in
        --push) PUSH=true ;;
    esac
done

check_jellyfin() {
    if ! curl -sf "$JELLYFIN_URL/System/Ping" > /dev/null 2>&1; then
        echo "Error: Jellyfin not reachable at $JELLYFIN_URL"
        echo "Make sure Jellyfin is running and the drive is connected."
        exit 1
    fi
}

authenticate() {
    local response
    response=$(curl -sf "$JELLYFIN_URL/Users/authenticatebyname" \
        -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: MediaBrowser Client=\"SyncScript\", Device=\"CLI\", DeviceId=\"sync-script\", Version=\"1.0\"" \
        -d "{\"Username\":\"$JELLYFIN_USER\",\"Pw\":\"$JELLYFIN_PASS\"}" 2>/dev/null) || {
        echo "Error: Failed to authenticate with Jellyfin"
        exit 1
    }

    USER_ID=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['User']['Id'])" 2>/dev/null)
    ACCESS_TOKEN=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessToken'])" 2>/dev/null)

    if [ -z "$USER_ID" ] || [ -z "$ACCESS_TOKEN" ]; then
        echo "Error: Could not parse authentication response"
        exit 1
    fi
}

fetch_library() {
    local items
    items=$(curl -sf "$JELLYFIN_URL/Users/$USER_ID/Items?Recursive=true&IncludeItemTypes=Movie,Series&Fields=Path,Genres,CommunityRating,ProductionYear,Overview&SortBy=SortName&SortOrder=Ascending&Limit=10000" \
        -H "X-Emby-Token: $ACCESS_TOKEN" 2>/dev/null) || {
        echo "Error: Failed to fetch library items"
        exit 1
    }
    echo "$items"
}

build_library_json() {
    local raw_items="$1"
    python3 << 'PYEOF' - "$raw_items" "$LIBRARY_JSON"
import json, sys

raw = json.loads(sys.argv[1])
output_path = sys.argv[2]
items = raw.get("Items", [])

library = {
    "synced_at": __import__("datetime").datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "total_count": len(items),
    "items": []
}

for item in items:
    entry = {
        "name": item.get("Name", ""),
        "year": item.get("ProductionYear"),
        "type": item.get("Type", ""),
        "genres": item.get("Genres", []),
        "rating": item.get("CommunityRating"),
        "path": item.get("Path", ""),
        "jellyfin_id": item.get("Id", ""),
    }
    library["items"].append(entry)

with open(output_path, "w") as f:
    json.dump(library, f, indent=2, ensure_ascii=False)

print(f"Wrote {len(items)} items to {output_path}")
PYEOF
}

generate_html() {
    python3 << 'PYEOF' - "$LIBRARY_JSON" "$COMMENTS_JSON" "$HTML_FILE"
import json, sys, html
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

# Build a lookup: normalized title -> comment
comment_lookup = {}
for category, films in comments.items():
    for title, comment in films.items():
        # Strip common file artifacts from title for matching
        clean = title.split("[")[0].split("(")[0].strip()
        comment_lookup[clean.lower()] = comment
        comment_lookup[title.lower()] = comment

# Categorize items from Jellyfin using genres and path
# Also try to match against existing film_comments.json categories
category_map = {}  # category -> list of items
comments_categories = list(comments.keys())

for item in library["items"]:
    name = item["name"]
    year = item.get("year")
    display = f"{name} ({year})" if year else name
    genres = item.get("genres", [])
    path = item.get("path", "")

    matched_category = None
    name_lower = name.lower()
    display_lower = display.lower()

    # Try to find which film_comments category this belongs to
    for cat, films in comments.items():
        for title in films:
            title_clean = title.split("[")[0].split("(")[0].strip().lower()
            if title_clean == name_lower or name_lower in title.lower() or title_clean in display_lower:
                matched_category = cat
                break
        if matched_category:
            break

    if not matched_category:
        # Fall back to genre-based categorization
        if any(g in ["Animation", "Anime"] for g in genres):
            matched_category = "Anime movies"
        elif any(g in genres for g in ["Bollywood", "Indian"]):
            matched_category = "Indian Films"
        else:
            matched_category = "Movies in General"

    if matched_category not in category_map:
        category_map[matched_category] = []

    # Try to find comment
    comment = comment_lookup.get(name_lower, "")
    if not comment:
        comment = comment_lookup.get(display_lower, "")

    category_map[matched_category].append({
        "display": display,
        "comment": comment,
        "type": item.get("type", "Movie"),
    })

# Sort categories and films
for cat in category_map:
    category_map[cat].sort(key=lambda x: x["display"].lower())

# Preserve category order from film_comments.json, then add new ones
ordered_cats = []
for cat in comments_categories:
    if cat in category_map:
        ordered_cats.append(cat)
for cat in sorted(category_map.keys()):
    if cat not in ordered_cats:
        ordered_cats.append(cat)

synced_at = library.get("synced_at", "unknown")
total = library.get("total_count", sum(len(v) for v in category_map.values()))

# Generate HTML
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

# Build category options for dropdown
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
            max-width: 900px;
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
            margin-bottom: 1.5rem;
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
            <input type="text" id="searchInput" placeholder="Search films..." oninput="filterFilms()">
        </div>
        <select class="category-filter" id="categoryFilter" onchange="filterByCategory()">
{options_html}
        </select>
    </div>

    <div id="filmContainer">
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

    function filterFilms() {{
        const query = document.getElementById('searchInput').value.toLowerCase().trim();
        const selectedCategory = document.getElementById('categoryFilter').value;
        const sections = document.querySelectorAll('.category-section');
        let totalVisibleFilms = 0;

        sections.forEach(section => {{
            const categoryName = section.getAttribute('data-category');
            const matchCategory = (selectedCategory === 'all' || categoryName === selectedCategory);

            if (!matchCategory) {{
                section.style.display = 'none';
                return;
            }}

            section.style.display = 'block';
            const items = section.querySelectorAll('.film-item');
            let sectionHasMatch = false;

            items.forEach(item => {{
                const text = item.textContent.toLowerCase();
                if (text.includes(query)) {{
                    item.style.display = 'flex';
                    sectionHasMatch = true;
                    totalVisibleFilms++;
                }} else {{
                    item.style.display = 'none';
                }}
            }});

            if (sectionHasMatch) {{
                section.style.display = 'block';
                if (query.length > 0) {{
                    section.classList.add('open');
                }}
            }} else {{
                section.style.display = 'none';
            }}
        }});

        const noResults = document.getElementById('noResults');
        if (totalVisibleFilms === 0) {{
            noResults.style.display = 'block';
        }} else {{
            noResults.style.display = 'none';
        }}
    }}

    function filterByCategory() {{
        filterFilms();
    }}
</script>

</body>
</html>'''

with open(html_path, "w") as f:
    f.write(page)

print(f"Generated {html_path} with {total} films in {len(ordered_cats)} categories")
PYEOF
}

push_to_github() {
    cd "$SCRIPT_DIR"
    git add library.json film-library.html
    git commit -m "Update film library ($(date +%Y-%m-%d))" || {
        echo "No changes to commit"
        return 0
    }
    git push
}

echo "=== Jellyfin Library Sync ==="
echo "Connecting to $JELLYFIN_URL..."

check_jellyfin
echo "Jellyfin is running."

echo "Authenticating..."
authenticate
echo "Authenticated as $JELLYFIN_USER."

echo "Fetching library..."
RAW_ITEMS=$(fetch_library)
echo "Library fetched."

echo "Building library.json..."
build_library_json "$RAW_ITEMS"

echo "Generating HTML..."
generate_html

if $PUSH; then
    echo "Pushing to GitHub..."
    push_to_github
    echo "Done. Library synced and pushed."
else
    echo "Done. Run with --push to commit and push to GitHub."
fi
