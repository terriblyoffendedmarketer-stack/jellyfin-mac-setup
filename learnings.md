# Learnings

what broke | why | what fixed it
---|---|---
FFmpeg temp file on ExFAT had `.tmp` extension | FFmpeg couldn't determine output container format from `.tmp` | Use `.normalizing.mp4` (keep original extension)
MP4 metadata title not detected | MP4 stores audio track title in `tags.name`, not `tags.title` like MKV | Check both `title` and `name` fields in ffprobe output
macOS `._` resource fork files cause rglob errors on ExFAT | macOS creates `._*` metadata files that can vanish between glob and unlink | Skip `._` prefixed files in cleanup, wrap in try/except
FFmpeg process times out on USB drive | USB drive I/O is slow (~30MB/s), 300MB file takes >5 min to process | Increased timeout from 600s to 1800s (30 min)
Dirty USB eject locks files with `uchg` flag on ExFAT | macOS sets user immutable flag on ExFAT files after unclean disconnect | Run `chflags nouchg` before replace; added auto-unlock to normalize script
ebur128 regex grabbed first frame (-70 LUFS) not summary | `re.search` returns first match; first ebur128 frame has no data yet | Use `re.findall` and take last match (the summary values)
