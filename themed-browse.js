(function() {
  'use strict';

  var COLLECTIONS = [
    { id: '488266c804d060caca9bd83c6f085a8c', name: 'Korean Thrillers' },
    { id: '54fafbe5186b31efb505999d4ef4e366', name: 'Visually Stunning' },
    { id: 'fc807d5dcf51a8997fbbc574c8a49b35', name: 'Slow Burns' },
    { id: 'adb1cfa8f0eaac9e30caee5f1769dbc2', name: 'Horror That Lingers' },
    { id: '55d513c435a9041596296d11a3152a9b', name: 'Mind-Bending' },
    { id: '9cfe2633d49698c0f0b4352831e699f4', name: 'Feel-Good & Heartwarming' },
    { id: '0cebd8873fc67937a06a3dfa789ba2ed', name: 'Korean Romance' },
    { id: 'f145a56ae2590847ec93462d67846af8', name: 'Japanese Cinema' },
    { id: '6fe1ad72243f6c22bcbb508d46d8077b', name: 'Indian Cinema Gems' },
    { id: '7cc4a1ba1a727feb0b593be14d825243', name: 'Martial Arts & Action Cinema' },
    { id: '988af9e0e641f2d910e3d78878d63b10', name: 'Revenge & Vengeance' },
    { id: '068903946dab894170c681a785e0f90f', name: 'Coming of Age' },
    { id: 'bc25325c50b1293b590a3207c872f6e2', name: 'True Stories' },
    { id: 'ce85d04a7aca2d94a768aef276f0dc7e', name: 'War & Conflict' },
    { id: '6ffd25c7d6ed94f56c279ae8fa9d8d7d', name: 'One-Room Tension' },
    { id: '24d24ecae3c3880074210f1416a4e892', name: 'Wong Kar-wai' },
    { id: 'fdeec45dec6edefcc29cd801f9d220ca', name: 'Park Chan-wook' },
    { id: '53a99eb338e2fb59d9c484837866b810', name: 'Bong Joon-ho' },
    { id: '072f5cb763c98418309e6e4e6e677d30', name: 'Wes Anderson' },
    { id: '52b666764ff88ed9c8b151064a765779', name: 'Anime Films' },
    { id: '6e120c10473196130c6789f7e3b31a95', name: 'Harry Potter' }
  ];

  var apiToken = null;
  var userId = null;
  var serverUrl = '';

  function getCredentials() {
    try {
      var creds = JSON.parse(localStorage.getItem('jellyfin_credentials'));
      if (creds && creds.Servers && creds.Servers.length) {
        var server = creds.Servers[0];
        apiToken = server.AccessToken;
        userId = server.UserId;
        serverUrl = server.ManualAddress || '';
        return true;
      }
    } catch(e) {}
    return false;
  }

  function apiFetch(path) {
    return fetch(path, { headers: { 'X-Emby-Token': apiToken } })
      .then(function(r) { return r.ok ? r.json() : null; });
  }

  function getItemUrl(itemId) {
    return '#!/details?id=' + itemId;
  }

  function getImageUrl(itemId) {
    return '/Items/' + itemId + '/Images/Primary?maxHeight=300&quality=80';
  }

  function renderThemesPage() {
    if (!apiToken && !getCredentials()) return;

    var mainContent = document.querySelector('.mainDrawerContent') ||
                      document.querySelector('#skinBody') ||
                      document.querySelector('main') ||
                      document.querySelector('.view');

    if (!mainContent) return;

    var container = document.createElement('div');
    container.id = 'jf-themes-page';
    container.innerHTML = '<h1 style="padding: 0 1em; color: #fff; font-size: 1.6em; font-weight: 300; margin: 0.8em 0 0.3em;">Browse by Theme</h1>';

    var sectionsContainer = document.createElement('div');
    container.appendChild(sectionsContainer);

    mainContent.innerHTML = '';
    mainContent.appendChild(container);

    COLLECTIONS.forEach(function(coll) {
      var section = document.createElement('div');
      section.className = 'jf-theme-section';
      section.innerHTML = '<h2 class="jf-theme-title">' + coll.name + '</h2>' +
        '<div class="jf-theme-row"><div class="jf-theme-loading">Loading...</div></div>';
      sectionsContainer.appendChild(section);

      apiFetch('/Users/' + userId + '/Items?ParentId=' + coll.id +
        '&Fields=PrimaryImageAspectRatio,Overview&Limit=50&SortBy=Random&SortOrder=Ascending')
        .then(function(data) {
          if (!data || !data.Items || !data.Items.length) {
            section.querySelector('.jf-theme-row').innerHTML =
              '<div class="jf-theme-loading">No items</div>';
            return;
          }
          var row = section.querySelector('.jf-theme-row');
          row.innerHTML = '';
          data.Items.forEach(function(item) {
            var card = document.createElement('a');
            card.className = 'jf-theme-card';
            card.href = getItemUrl(item.Id);
            card.setAttribute('data-id', item.Id);

            var hasImage = item.ImageTags && item.ImageTags.Primary;
            var imgHtml = hasImage ?
              '<img src="' + getImageUrl(item.Id) + '" alt="' +
                item.Name.replace(/"/g, '&quot;') + '" loading="lazy">' :
              '<div class="jf-theme-noimg">' + item.Name + '</div>';

            card.innerHTML = imgHtml +
              '<div class="jf-theme-card-name">' + item.Name + '</div>';

            if (item.ProductionYear) {
              card.innerHTML += '<div class="jf-theme-card-year">' + item.ProductionYear + '</div>';
            }

            row.appendChild(card);
          });
        });
    });
  }

  function addThemesNavLink() {
    var checkNav = setInterval(function() {
      var navItems = document.querySelectorAll('.navMenuOption, .mainDrawer a[data-itemid]');
      if (navItems.length === 0) return;
      clearInterval(checkNav);

      var existing = document.querySelector('#jf-themes-nav');
      if (existing) return;

      var collectionsLink = null;
      navItems.forEach(function(el) {
        if (el.textContent.trim().toLowerCase() === 'collections') {
          collectionsLink = el;
        }
      });

      var link = document.createElement('a');
      link.id = 'jf-themes-nav';
      link.className = collectionsLink ? collectionsLink.className : 'navMenuOption';
      link.href = '#!/themes';
      link.innerHTML = '<span class="navMenuOptionIcon flex-shrink-zero md-icon">style</span>' +
        '<span class="navMenuOptionText">Themes</span>';
      link.addEventListener('click', function(e) {
        e.preventDefault();
        window.location.hash = '#!/themes';
        setTimeout(renderThemesPage, 100);
        var drawer = document.querySelector('.mainDrawer');
        if (drawer && drawer.classList.contains('is-open')) {
          drawer.classList.remove('is-open');
          var overlay = document.querySelector('.mainDrawerHandle');
          if (overlay) overlay.click();
        }
      });

      if (collectionsLink && collectionsLink.parentNode) {
        collectionsLink.parentNode.insertBefore(link, collectionsLink.nextSibling);
      }
    }, 1000);
  }

  function handleHashChange() {
    if (window.location.hash === '#!/themes') {
      setTimeout(renderThemesPage, 200);
    }
  }

  function injectStyles() {
    var style = document.createElement('style');
    style.textContent =
      '.jf-theme-section { padding: 0 0 1.5em; }' +
      '.jf-theme-title { color: #fff; font-size: 1.25em; font-weight: 400; padding: 0 1em; margin: 0 0 0.5em; }' +
      '.jf-theme-row { display: flex; overflow-x: auto; gap: 0.7em; padding: 0 1em; scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.2) transparent; }' +
      '.jf-theme-row::-webkit-scrollbar { height: 6px; }' +
      '.jf-theme-row::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.2); border-radius: 3px; }' +
      '.jf-theme-card { flex: 0 0 150px; text-decoration: none; cursor: pointer; position: relative; transition: transform 0.2s; }' +
      '.jf-theme-card:hover { transform: scale(1.05); }' +
      '.jf-theme-card img { width: 150px; height: 225px; object-fit: cover; border-radius: 4px; display: block; }' +
      '.jf-theme-noimg { width: 150px; height: 225px; background: #333; border-radius: 4px; display: flex; align-items: center; justify-content: center; color: #aaa; font-size: 0.8em; text-align: center; padding: 0.5em; }' +
      '.jf-theme-card-name { color: #ccc; font-size: 0.75em; padding: 0.3em 0 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 150px; }' +
      '.jf-theme-card-year { color: #888; font-size: 0.65em; }' +
      '.jf-theme-loading { color: #888; padding: 1em; font-size: 0.9em; }' +
      '#jf-themes-nav { display: flex !important; align-items: center; gap: 0; }';
    document.head.appendChild(style);
  }

  function init() {
    getCredentials();
    injectStyles();
    addThemesNavLink();
    window.addEventListener('hashchange', handleHashChange);
    if (window.location.hash === '#!/themes') {
      setTimeout(renderThemesPage, 500);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    setTimeout(init, 500);
  }
})();
