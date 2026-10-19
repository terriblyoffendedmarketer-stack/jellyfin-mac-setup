# Learnings

what broke | why | what fixed it
---|---|---
FFmpeg temp file on ExFAT had `.tmp` extension | FFmpeg couldn't determine output container format from `.tmp` | Use `.normalizing.mp4` (keep original extension)
MP4 metadata title not detected | MP4 stores audio track title in `tags.name`, not `tags.title` like MKV | Check both `title` and `name` fields in ffprobe output
macOS `._` resource fork files cause rglob errors on ExFAT | macOS creates `._*` metadata files that can vanish between glob and unlink | Skip `._` prefixed files in cleanup, wrap in try/except
FFmpeg process times out on USB drive | USB drive I/O is slow (~30MB/s), 300MB file takes >5 min to process | Increased timeout from 600s to 1800s (30 min)
Dirty USB eject locks files with `uchg` flag on ExFAT | macOS sets user immutable flag on ExFAT files after unclean disconnect | Run `chflags nouchg` before replace; added auto-unlock to normalize script
ebur128 regex grabbed first frame (-70 LUFS) not summary | `re.search` returns first match; first ebur128 frame has no data yet | Use `re.findall` and take last match (the summary values)
Jellyfin DELETE /Items/{id} deletes PHYSICAL FILES from disk | API design — it's a permanent delete, not a library removal | NEVER use DELETE /Items. Use POST /Items/{id}/Refresh to re-index. Lost ReLIFE + Monogatari files this way.
Server ID changes after database migration | `device.txt` in `.jellyfin-data/` gets regenerated when DB rebuilds (e.g. disk space crisis) | All clients show "Server Mismatch" — must Clear Data in app settings, not just delete/re-add server
Sony Bravia TV "Unable to connect" after server ID change | Clear Data alone doesn't flush in-memory state on old Android TV | Force-stop the Jellyfin app **4+ times** after Clear Data, then re-enter server URL. Multiple kill cycles needed.
Mac Home page shows "Nothing here" | DisplayPreferences had homesection2-6 set to "none" | Fix via API: POST DisplayPreferences with homesection0=smalllibrarytiles, 1=resume, 2=nextup, 3=latestmedia. Then Cmd+Shift+R.
Jellyfin misidentified Monogatari Series as "Mashin Hero Wataru" | TMDB fuzzy matching on "Monogatari Series" folder name | Use POST /Items/RemoteSearch/Apply/{id} with correct TMDB provider ID to force correct identification
Monogatari Series TMDB structure (ID 46195) | TMDB treats it as 4 seasons + specials, NOT 13 separate seasons | S1=Bakemonogatari(12), S2=Nisemonogatari(11), S3=Second Season(23), S4=Owarimonogatari(12-13). Everything else (Neko Kuro, Hana, Tsuki, Koyomi, Owari S2, Zoku) goes in Specials with specific episode numbers.
Kizumonogatari are separate movies on TMDB | Not part of the Monogatari TV series entry | Don't put them in TV season folders — use .ignore or a separate Movies entry
Jellyfin .ignore file | Place a file named `.ignore` in any directory to make Jellyfin skip it during library scan | Used to exclude the BD source folder and Kizumonogatari movies from the TV series scan
Jellyfin needs 2GB free on datadir filesystem | Below 2GB, Jellyfin refuses to start or behaves erratically | Clear pip/Homebrew caches, delete old backups to free space
Launch Jellyfin via `open /Applications/Jellyfin.app` | Launching the binary directly causes jellyfin-web path errors and SQLite migration failures | Always use `open` command, not the binary. The .app wrapper sets correct --webdir and handles migrations.
ServerName blank causes discovery issues | system.xml had `<ServerName />` (empty) | Set to `<ServerName>jf</ServerName>` — helps clients find the server
Travel mode hung: Jellyfin process alive but port 8096 never opened (drive unplugged) | jellyfin-mode never swapped `cache` (always -> drive), and opening Jellyfin.app directly skipped the mode switch, leaving root -> drive and data/config as un-linked plain folders | jellyfin-mode now swaps cache too (cache.travel) and repairs plain data/config folders back to *.travel; run `bash ~/jellyfin-mac-setup/jellyfin-mode auto --start` if Jellyfin won't open
Normalizing new drive items took forever | normalize-sidecar.py ffprobes every video (over USB) before its sidecar check | scripts/find-unprocessed.py lists names only, then normalize/loudnorm `--files-from` the short list
Test of a .command with piped input started a real 488-item run | the confirm prompt defaulted to Yes and an empty read = yes; drive had been plugged in meanwhile | Confirm defaults to No (`read ... || GO=n`); test .command files only on a fake drive copy (DRIVE= replaced)
bash 3.2 (macOS) + `set -u`: "${ARR[@]}" on an empty array = "unbound variable" | old bash quirk | use ${ARR[@]+"${ARR[@]}"}
Sidecars covering only part of a film, logged "done" | normalize-sidecar.py kept failed ffmpeg output if > 100 KB (interrupted run / unplugged drive) | non-zero exit kept only if -progress out_time >= 97% of film; loudnorm: non-zero exit = fail. 17 found by `find-unprocessed.py --audit`
ffprobe format=duration on a raw .aac sidecar is wrong (bitrate guess: 139 min for a 68 min file) | ADTS has no length header | count frames: -count_packets nb_read_packets x 1024 / sample_rate (<1 s)
Killing a test ffmpeg with pkill -f "ffmpeg.*name" matched my own shell command | -f matches full command lines incl. the shell running pkill | select by process name: ps -axo pid=,comm=,args= | awk '$2 ~ /ffmpeg$/ && /name/'
