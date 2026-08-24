# Movie Calendar Handoff

## What This Is
Bulk calendar operations for the "Movie Plans" Google Calendar — all tasks complete.

## Calendar IDs
- **Primary (pjdruck@gmail.com):** `pjdruck@gmail.com`
- **Movie Plans:** `269d7d84e2049883815c6937f5a138583f3584e2063caaa933ec7a2a2399e636@group.calendar.google.com`

## Status

### 1. Delete movie events from primary calendar — DONE
- All 154 wrongly-imported movie events deleted from primary calendar

### 2. Create 549 daily film events on Movie Plans — DONE
- 549 all-day events created (280 via API, 269 via ICS import)
- Date range: 2026-08-23 to 2028-02-22
- All marked as free (not busy), timezone Asia/Kolkata

### 3. Create 39 biweekly theme events on Movie Plans — DONE
- 39 theme events created via API
- Themes are fun/exciting, not film-school homework

### 4. Calendar auto-swap for new films — DONE
- Google Apps Script webhook deployed (`calendar-swap.gs`)
- `sync-library.sh` detects new films added to Jellyfin and calls the webhook
- New films get swapped into upcoming calendar slots (1-2 this week, rest peppered over next 2-3 weeks)
- Displaced films moved to end of calendar
- Fully hands-off — runs automatically via existing LaunchAgent every 5 min
