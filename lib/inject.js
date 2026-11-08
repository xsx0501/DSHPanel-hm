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
})();`
}
