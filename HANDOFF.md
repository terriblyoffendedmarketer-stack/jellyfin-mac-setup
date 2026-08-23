# Movie Calendar Handoff

## What This Is
Bulk calendar operations for the "Movie Plans" Google Calendar — deleting wrongly-imported events from the primary calendar and creating 538 daily film events on the correct calendar.

## Calendar IDs
- **Primary (pjdruck@gmail.com):** `pjdruck@gmail.com` — movie events here need DELETING
- **Movie Plans:** `269d7d84e2049883815c6937f5a138583f3584e2063caaa933ec7a2a2399e636@group.calendar.google.com` — events go HERE

## Status

### 1. Delete movie events from primary calendar
- **Total:** 200 events to delete
- **Done:** 45 deleted
- **Remaining:** 155 — IDs in `remaining_event_ids.json`
- Use Google Calendar API `delete_event` with `calendarId=pjdruck@gmail.com` and `notificationLevel=NONE`

### 2. Create 538 daily film events on Movie Plans
- **NOT STARTED**
- All 538 events pre-built in `calendar_events.json`
- Each entry has: day number, date, film name, vibe classification, description (with curated comments)
- Date range: 2026-08-23 to 2028-02-11
- Create as **all-day events**, marked as **free** (not busy)
- Timezone: Asia/Kolkata
- Use `create_event` with:
  - `calendarId`: the Movie Plans ID above
  - `title`: the `name` field
  - `description`: the `description` field
  - `start`/`end`: the `date` field (all-day)
  - `availability`: FREE
  - `timeZone`: Asia/Kolkata

### 3. Design biweekly theme events
- **NOT STARTED**
- Create exciting biweekly theme events on Movie Plans calendar
- Themes should be fun/exciting, NOT "film school homework"
- Lead with excitement, not study — user enjoys art/indie films but wants joy

## Film Sequencing Algorithm
- Films classified into light/medium/heavy vibes
- Interleaved with pattern: L, H, L, M, L, H, L, M, H, L (repeating)
- Max consecutive heavy films: 1
- Joy peppered throughout — no clusters of back-to-back heavy/art films
- Script: `build_sequence.py` (can re-run to regenerate if needed)

## User Preferences
- Enjoys indie, art, and parallel cinema — don't remove them
- Wants more joy/fun peppered in, not clustered heavy watching
- Don't overcorrect by replacing art films with mainstream blockbusters
- Login: pjdruck / 8544
- Timezone: Asia/Kolkata