/**
 * The single script injected into DSH's index.html by `webserver/index-inject`.
 *
 * Keep this intentionally tiny: the page already has DSH's own client runtime and
 * a live WebSocket mux. The bridge only needs to
 *   1. tell the page a native container is present,
 *   2. accept a compact state snapshot pushed by the native side (for pause/resume),
 *   3. let the page hand back a one-line status hint the native side can trust
 *      when the phone is in the foreground.
 *
 * No credentials, no token, no fetch interception here.
 */
export function bridgeScript() {
  return `;(function () {
  if (window.__DSH_PANEL__) return;
  var listeners = new Set();
  window.__DSH_PANEL__ = {
    version: 1,
    bridge: 'native',
    paused: false,
    onNativeState: function (fn) { listeners.add(fn); return function () { listeners.delete(fn); }; },
    applyNativeState: function (state) {
      window.__DSH_PANEL__.paused = state && state.paused === true;
      listeners.forEach(function (fn) { try { fn(state); } catch (_) {} });
    },
    reportHint: function (hint) {
      try { window.harmonyPanelBridge && window.harmonyPanelBridge.onHint(JSON.stringify(hint)); } catch (_) {}
    }
  };

  // Pairing entry point. It belongs in the left icon rail next to DSH's own
  // navigation; a floating button would sit on top of the composer's send button.
  // The rail carries no stable class name, so it is found structurally, and a
  // left-edge fallback keeps it out of the composer when the layout changes.
  var QR_ICON = '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor"' +
    ' stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
    '<rect x="3" y="3" width="7" height="7" rx="1.5"></rect>' +
    '<rect x="14" y="3" width="7" height="7" rx="1.5"></rect>' +
    '<rect x="3" y="14" width="7" height="7" rx="1.5"></rect>' +
    '<path d="M14 14h3v3h-3zM20 14h1M14 20h3M20 18v3"></path></svg>';

  function looksLikeRail(el) {
    if (el.id === 'dsh-panel-pair') return false;
    var r = el.getBoundingClientRect();
    if (r.width < 36 || r.width > 120) return false;
    if (r.height < window.innerHeight * 0.5) return false;
    if (r.left > 8) return false;
    var items = 0;
    for (var i = 0; i < el.children.length; i++) {
      var c = el.children[i];
      var cr = c.getBoundingClientRect();
      if (cr.width >= 24 && cr.width <= 120 && cr.height >= 24 && cr.height <= 120) items++;
    }
    return items >= 3;
  }

  function findRail() {
    var best = null;
    var bestItems = 0;
    var all = document.body.getElementsByTagName('*');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (!looksLikeRail(el)) continue;
      if (el.children.length > bestItems) { best = el; bestItems = el.children.length; }
    }
    return best;
  }

  function buildItem() {
    var a = document.createElement('a');
    a.id = 'dsh-panel-pair';
    a.href = '/panel';
    a.target = '_blank';
    a.rel = 'noopener';
    a.title = '扫码配对：把手机连上 DSH 面板';
    a.setAttribute('aria-label', '扫码配对');
    a.innerHTML = QR_ICON;
    a.style.cssText = [
      'display:flex', 'align-items:center', 'justify-content:center',
      'width:40px', 'height:40px', 'margin:6px auto 0', 'border-radius:10px',
      'color:inherit', 'opacity:.72', 'text-decoration:none', 'cursor:pointer'
    ].join(';');
    a.onmouseenter = function () { a.style.opacity = '1'; a.style.background = 'rgba(127,127,127,.14)'; };
    a.onmouseleave = function () { a.style.opacity = '.72'; a.style.background = 'transparent'; };
    return a;
  }

  function mountPairEntry() {
    if (document.getElementById('dsh-panel-pair')) return;
    var item = buildItem();
    var rail = findRail();
    if (rail !== null) {
      rail.appendChild(item);
      return;
    }
    // Fallback: left edge, well above the composer, vertically centred-ish.
    item.style.position = 'fixed';
    item.style.left = '12px';
    item.style.bottom = '96px';
    item.style.zIndex = '2147483000';
    item.style.background = 'rgba(127,127,127,.10)';
    document.body.appendChild(item);
  }

  var mounted = false;
  function scheduleMount() {
    if (mounted) return;
    mounted = true;
    mountPairEntry();
    // The rail may mount after us (the client renders asynchronously); retry a few
    // times and stop as soon as the entry is in place.
    var tries = 0;
    var timer = setInterval(function () {
      tries++;
      var present = document.getElementById('dsh-panel-pair');
      if (present === null && tries <= 20) mountPairEntry();
      else if (tries > 20 || present !== null) {
        if (present !== null && present.parentNode === document.body && tries <= 20) {
          var rail = findRail();
          if (rail !== null) rail.appendChild(present);
        }
        clearInterval(timer);
      }
    }, 500);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', scheduleMount);
  } else {
    scheduleMount();
  }
})();`
}
