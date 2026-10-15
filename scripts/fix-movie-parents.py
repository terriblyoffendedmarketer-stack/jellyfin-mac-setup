#!/usr/bin/env python3
# fix-movie-parents.py — Re-links movies that Jellyfin shows as missing from the Movies library because their
# TopParentId points at a library location that no longer exists (e.g. "/Volumes/Backup Plus/All Movies" after the
# library was switched back to per-category locations). Sets each item's TopParentId to its category folder and
# removes the stale ancestor links. No files touched; watch history (UserData) is kept.
#
# Usage (Jellyfin MUST be stopped):  python3 scripts/fix-movie-parents.py [--dry-run]
# Requires: python3 stdlib. Backs up jellyfin.db first to jellyfin.db.pre-fix-<timestamp>.
#
# Gotchas:
#   - Jellyfin IDs are deterministic: Folder id = MD5(UTF-16LE("MediaBrowser.Controller.Entities.Folder" + path)) as a
#     .NET Guid (bytes_le). Library (CollectionFolder) id = same with key "root\default\<Name>" (path relative to
#     program data, backslashes, case-sensitive).
#   - A library scan does NOT re-parent existing items whose TopParentId is stale; only new items get the right one.
#     That's why the films stayed invisible after changing library locations.
#   - Library membership = TopParentId equal to one of the library's location folders (+ AncestorIds); working items
#     have ancestors {category folder, root} only.
import hashlib, shutil, sqlite3, sys, time, uuid, os

DB = "/Volumes/Backup Plus/.jellyfin-data/jellyfin.db"
ROOT = "/Volumes/Backup Plus/All Movies"
STALE_TOP = "MediaBrowser.Controller.Entities.Folder" + ROOT
LIB_KEY = "MediaBrowser.Controller.Entities.CollectionFolder" + "root\\default\\Movies"


def jid(key):
    return str(uuid.UUID(bytes_le=hashlib.md5(key.encode("utf-16-le")).digest())).upper()


def main():
    dry = "--dry-run" in sys.argv
    stale, lib = jid(STALE_TOP), jid(LIB_KEY)
    if not dry:
        bak = f"{DB}.pre-fix-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(DB, bak)
        for ext in ("-wal", "-shm"):
            if os.path.exists(DB + ext):
                shutil.copy2(DB + ext, bak + ext)
        print("backup:", bak)
    con = sqlite3.connect(DB)
    rows = con.execute("select Id, Path from BaseItems where TopParentId=? and Path like ?", (stale, ROOT + "/%/%")).fetchall()
    fixed = 0
    for item_id, path in rows:
        cat = path[len(ROOT) + 1:].split("/")[0]
        cat_id = jid("MediaBrowser.Controller.Entities.Folder" + ROOT + "/" + cat)
        if not dry:
            con.execute("update BaseItems set TopParentId=? where Id=?", (cat_id, item_id))
            con.execute("delete from AncestorIds where ItemId=? and ParentItemId in (?,?)", (item_id, stale, lib))
        fixed += 1
    if not dry:
        con.commit()
    print(f"{'would fix' if dry else 'fixed'} {fixed} items (stale top parent {stale})")


if __name__ == "__main__":
    main()
