(function() {
  'use strict';
  var cache = {};
  var apiToken = null;
  var userId = null;

  function getCredentials() {
    try {
      var creds = JSON.parse(localStorage.getItem('jellyfin_credentials'));
      if (creds && creds.Servers && creds.Servers.length) {
        var server = creds.Servers[0];
        apiToken = server.AccessToken;
        userId = server.UserId;
        return true;
      }
    } catch(e) {}
    return false;
  }

  function fetchOverview(itemId) {
    if (cache[itemId] !== undefined) return Promise.resolve(cache[itemId]);
    if (!apiToken && !getCredentials()) return Promise.resolve(null);
    return fetch('/Users/' + userId + '/Items/' + itemId + '?Fields=Overview',
      { headers: { 'X-Emby-Token': apiToken } })
      .then(function(r) { return r.ok ? r.json() : null; })
      .then(function(data) {
        if (!data) return null;
        cache[itemId] = data.Overview || '';
        return cache[itemId];
      })
      .catch(function() { return null; });
  }

  function processCard(card) {
    if (card.querySelector('.jf-hover-overlay')) return;
    var itemId = card.getAttribute('data-id');
    if (!itemId) return;
    var scalable = card.querySelector('.cardScalable');
    if (!scalable) return;
    var overlay = document.createElement('div');
    overlay.className = 'jf-hover-overlay';
    scalable.appendChild(overlay);
    var loaded = false;
    card.addEventListener('mouseenter', function() {
      if (loaded) return;
      loaded = true;
      fetchOverview(itemId).then(function(overview) {
        if (overview) { overlay.textContent = overview; }
        else { overlay.remove(); }
      });
    });
  }

  function processAllCards() {
    document.querySelectorAll('.card[data-type="Movie"]').forEach(processCard);
  }

  var observer = new MutationObserver(function(mutations) {
    for (var i = 0; i < mutations.length; i++) {
      if (mutations[i].addedNodes.length) {
        requestAnimationFrame(processAllCards);
        return;
      }
    }
  });

  function init() {
    getCredentials();
    processAllCards();
    observer.observe(document.body, { childList: true, subtree: true });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    setTimeout(init, 500);
  }
})();
