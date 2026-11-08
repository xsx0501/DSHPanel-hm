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

  // Pairing entry point: a small floating button that opens the server-rendered
  // /panel card (QR + deep link). It carries no credentials itself.
  function mountPairButton() {
    if (document.getElementById('dsh-panel-pair')) return;
    var a = document.createElement('a');
    a.id = 'dsh-panel-pair';
    a.href = '/panel';
    a.target = '_blank';
    a.rel = 'noopener';
    a.title = 'DSH 面板配对：扫码把手机连上';
    a.textContent = '配对';
    a.style.cssText = [
      'position:fixed', 'right:16px', 'bottom:16px', 'z-index:2147483000',
      'padding:8px 14px', 'border-radius:999px', 'background:#0a59f7', 'color:#fff',
      'font:500 13px/1.2 -apple-system,"HarmonyOS Sans","PingFang SC",system-ui,sans-serif',
      'text-decoration:none', 'box-shadow:0 6px 18px rgba(10,89,247,.35)', 'opacity:.92'
    ].join(';');
    a.onmouseenter = function () { a.style.opacity = '1'; };
    a.onmouseleave = function () { a.style.opacity = '.92'; };
    document.body.appendChild(a);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', mountPairButton);
  } else {
    mountPairButton();
  }
})();`
}
