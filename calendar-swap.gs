// calendar-swap.gs — Auto-inserts new Jellyfin films into Movie Plans calendar
// Deployed as Google Apps Script web app, called by sync-library.sh
//
// Setup:
//   1. Go to script.google.com > New Project
//   2. Paste this entire file
//   3. Click Run > testAccess, authorize when prompted (grants Calendar access)
//   4. Deploy > New deployment > Type: Web app
//      - Execute as: Me
//      - Who has access: Anyone
//   5. Copy the web app URL
//   6. On Mac, run: echo 'YOUR_URL_HERE' > ~/jellyfin-mac-setup/.calendar-swap-url
//   7. Done — sync-library.sh will call it automatically when new films are detected
//
// Gotchas:
// - Must authorize Calendar access via testAccess() before the webhook works
// - "Anyone" access means anyone with the URL can POST — URL is the secret
// - If you redeploy, the URL changes — update .calendar-swap-url
// - Apps Script has a 6-min execution limit; 10+ swaps in one call is fine

var CALENDAR_ID = '269d7d84e2049883815c6937f5a138583f3584e2063caaa933ec7a2a2399e636@group.calendar.google.com';

function doPost(e) {
  try {
    var data = JSON.parse(e.postData.contents);
    var newFilms = data.films;

    if (!newFilms || newFilms.length === 0) {
      return jsonResponse({status: 'ok', message: 'No films to process'});
    }

    var calendar = CalendarApp.getCalendarById(CALENDAR_ID);
    if (!calendar) {
      return jsonResponse({status: 'error', message: 'Calendar not found — run testAccess() first'});
    }

    var now = new Date();
    var tomorrow = new Date(now);
    tomorrow.setDate(tomorrow.getDate() + 1);
    tomorrow.setHours(0, 0, 0, 0);

    var farFuture = new Date(now);
    farFuture.setFullYear(farFuture.getFullYear() + 3);

    var futureEvents = calendar.getEvents(tomorrow, farFuture);

    if (futureEvents.length === 0) {
      var date = new Date(tomorrow);
      for (var i = 0; i < newFilms.length; i++) {
        var ev = calendar.createAllDayEvent(newFilms[i].title, date);
        if (newFilms[i].description) ev.setDescription(newFilms[i].description);
        date = new Date(date);
        date.setDate(date.getDate() + 1);
      }
      return jsonResponse({status: 'ok', created: newFilms.length, swapped: 0});
    }

    futureEvents.sort(function(a, b) { return a.getStartTime() - b.getStartTime(); });

    var existingTitles = {};
    for (var i = 0; i < futureEvents.length; i++) {
      existingTitles[futureEvents[i].getTitle().toLowerCase()] = true;
    }
    var filmsToAdd = newFilms.filter(function(f) {
      return !existingTitles[f.title.toLowerCase()];
    });

    if (filmsToAdd.length === 0) {
      return jsonResponse({status: 'ok', message: 'All films already on calendar'});
    }

    var count = filmsToAdd.length;
    var thisWeekCount = Math.min(count, 2);
    var laterCount = count - thisWeekCount;

    var thisWeekEvents = [];
    var laterEvents = [];
    for (var i = 0; i < futureEvents.length; i++) {
      var daysDiff = (futureEvents[i].getStartTime() - tomorrow) / (1000 * 60 * 60 * 24);
      if (daysDiff < 3) {
        thisWeekEvents.push(futureEvents[i]);
      } else if (daysDiff >= 3 && daysDiff < 21) {
        laterEvents.push(futureEvents[i]);
      }
    }

    var lastEventDate = new Date(futureEvents[futureEvents.length - 1].getStartTime());
    var appendDate = new Date(lastEventDate);
    appendDate.setDate(appendDate.getDate() + 1);

    var swapped = 0;
    var appended = 0;

    var thisWeekSlots = pickRandom(thisWeekEvents, Math.min(thisWeekCount, thisWeekEvents.length));
    for (var i = 0; i < thisWeekSlots.length && i < filmsToAdd.length; i++) {
      var slot = thisWeekSlots[i];
      var film = filmsToAdd[i];

      var displacedTitle = slot.getTitle();
      var displacedDesc = slot.getDescription();

      slot.setTitle(film.title);
      slot.setDescription(film.description || '');

      var displaced = calendar.createAllDayEvent(displacedTitle, appendDate);
      if (displacedDesc) displaced.setDescription(displacedDesc);
      appendDate = new Date(appendDate);
      appendDate.setDate(appendDate.getDate() + 1);

      swapped++;
    }

    var laterSlots = pickRandom(laterEvents, Math.min(laterCount, laterEvents.length));
    for (var i = 0; i < laterSlots.length; i++) {
      var filmIdx = thisWeekCount + i;
      if (filmIdx >= filmsToAdd.length) break;

      var slot = laterSlots[i];
      var film = filmsToAdd[filmIdx];

      var displacedTitle = slot.getTitle();
      var displacedDesc = slot.getDescription();

      slot.setTitle(film.title);
      slot.setDescription(film.description || '');

      var displaced = calendar.createAllDayEvent(displacedTitle, appendDate);
      if (displacedDesc) displaced.setDescription(displacedDesc);
      appendDate = new Date(appendDate);
      appendDate.setDate(appendDate.getDate() + 1);

      swapped++;
    }

    var remaining = filmsToAdd.slice(swapped);
    for (var i = 0; i < remaining.length; i++) {
      var ev = calendar.createAllDayEvent(remaining[i].title, appendDate);
      if (remaining[i].description) ev.setDescription(remaining[i].description);
      appendDate = new Date(appendDate);
      appendDate.setDate(appendDate.getDate() + 1);
      appended++;
    }

    return jsonResponse({
      status: 'ok',
      swapped: swapped,
      appended: appended,
      total: filmsToAdd.length
    });

  } catch (err) {
    return jsonResponse({status: 'error', message: err.toString()});
  }
}

function pickRandom(arr, count) {
  var shuffled = arr.slice().sort(function() { return Math.random() - 0.5; });
  return shuffled.slice(0, count);
}

function jsonResponse(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

function testAccess() {
  var calendar = CalendarApp.getCalendarById(CALENDAR_ID);
  if (!calendar) {
    Logger.log('ERROR: Calendar not found. Make sure your Google account has access to the Movie Plans calendar.');
    return;
  }
  Logger.log('Calendar: ' + calendar.getName());
  var now = new Date();
  var future = new Date(now);
  future.setDate(future.getDate() + 7);
  var events = calendar.getEvents(now, future);
  Logger.log('Events in next 7 days: ' + events.length);
  for (var i = 0; i < events.length; i++) {
    Logger.log('  ' + events[i].getStartTime().toDateString() + ': ' + events[i].getTitle());
  }
  Logger.log('SUCCESS — Calendar access working. Deploy as web app now.');
}
