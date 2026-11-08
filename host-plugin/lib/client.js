window.__ModuleLoader__.load({
  id: "dsh-panel-bridge",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;
    Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

    let react = require("react");
    let h = react.createElement;

    /** Sidebar panel id; the same key addresses the main-column page. */
    const PANEL_ID = "dsh-panel-pairing";
    const API = "/api/panel/pairing";

    const styles = {
      page: {
        height: "100%",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        padding: "32px 20px",
        boxSizing: "border-box",
        color: "inherit"
      },
      card: {
        width: "100%",
        maxWidth: "460px",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        gap: "16px",
        padding: "28px 24px",
        borderRadius: "20px",
        border: "1px solid rgba(127,127,127,0.22)",
        background: "rgba(127,127,127,0.07)"
      },
      title: { fontSize: "17px", fontWeight: 600, margin: 0 },
      subtitle: { fontSize: "12px", opacity: 0.62, margin: 0, textAlign: "center", lineHeight: 1.6 },
      qr: {
        width: "232px",
        height: "232px",
        borderRadius: "16px",
        background: "#ffffff",
        padding: "10px",
        boxSizing: "border-box"
      },
      link: {
        width: "100%",
        fontSize: "11px",
        fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
        opacity: 0.66,
        wordBreak: "break-all",
        textAlign: "center",
        lineHeight: 1.5
      },
      row: { display: "flex", gap: "10px", width: "100%" },
      button: {
        flex: 1,
        height: "38px",
        borderRadius: "10px",
        border: "1px solid rgba(127,127,127,0.28)",
        background: "transparent",
        color: "inherit",
        fontSize: "13px",
        cursor: "pointer"
      },
      primary: {
        flex: 1,
        height: "38px",
        borderRadius: "10px",
        border: "none",
        background: "#0a59f7",
        color: "#ffffff",
        fontSize: "13px",
        fontWeight: 600,
        cursor: "pointer"
      }
    };

    function usePairing() {
      const [state, setState] = react.useState({ loading: true, ok: false, deepLink: "", qrUrl: "", endpoint: "" });
      const load = react.useCallback(() => {
        setState((prev) => ({ ...prev, loading: true }));
        fetch(API, { headers: { accept: "application/json" } })
          .then((res) => res.json())
          .then((body) => {
            setState({
              loading: false,
              ok: body && body.ok === true,
              deepLink: (body && body.deepLink) || "",
              qrUrl: (body && body.qrUrl) || "",
              endpoint: (body && body.endpoint) || ""
            });
          })
          .catch(() => setState({ loading: false, ok: false, deepLink: "", qrUrl: "", endpoint: "" }));
      }, []);
      react.useEffect(() => {
        load();
      }, [load]);
      return [state, load];
    }

    function PairingPage() {
      const [state, reload] = usePairing();
      const [copied, setCopied] = react.useState(false);
      const copy = () => {
        if (!state.deepLink) {
          return;
        }
        const done = () => {
          setCopied(true);
          setTimeout(() => setCopied(false), 1600);
        };
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(state.deepLink).then(done, done);
        } else {
          done();
        }
      };
      return h(
        "div",
        { style: styles.page },
        h(
          "div",
          { style: styles.card },
          h("h2", { style: styles.title }, "配对手机客户端"),
          h(
            "p",
            { style: styles.subtitle },
            state.endpoint ? `节点 ${state.endpoint}` : "读取节点信息…",
            h("br"),
            "用 DSHPanel 扫描二维码，令牌一次性有效"
          ),
          state.qrUrl
            ? h("img", { src: state.qrUrl, style: styles.qr, alt: "配对二维码" })
            : h(
                "div",
                { style: { ...styles.qr, display: "flex", alignItems: "center", justifyContent: "center", fontSize: "12px", color: "#666" } },
                state.loading ? "生成中…" : "暂不可用"
              ),
          state.deepLink ? h("div", { style: styles.link }, state.deepLink) : null,
          h(
            "div",
            { style: styles.row },
            h("button", { type: "button", style: styles.button, onClick: reload }, "刷新"),
            h("button", { type: "button", style: styles.primary, onClick: copy }, copied ? "已复制" : "复制链接")
          ),
          h(
            "p",
            { style: styles.subtitle },
            "也可以直接在浏览器打开 ",
            h("a", { href: "/panel", target: "_blank", rel: "noreferrer", style: { color: "#0a59f7" } }, "/panel"),
            " 查看桌面版配对页"
          )
        )
      );
    }

    function PairingIcon(props) {
      const size = (props && props.size) || 22;
      const active = !!(props && props.active);
      return h(
        "svg",
        { width: size, height: size, viewBox: "0 0 24 24", fill: "none", "aria-hidden": "true" },
        h("rect", {
          x: 3,
          y: 3,
          width: 7,
          height: 7,
          rx: 1.6,
          stroke: "currentColor",
          strokeWidth: 1.7,
          opacity: active ? 1 : 0.92
        }),
        h("rect", { x: 14, y: 3, width: 7, height: 7, rx: 1.6, stroke: "currentColor", strokeWidth: 1.7 }),
        h("rect", { x: 3, y: 14, width: 7, height: 7, rx: 1.6, stroke: "currentColor", strokeWidth: 1.7 }),
        h("path", {
          d: "M14 14h3v3h-3zM19 19h2v2h-2zM14 19h2v2h-2zM19 14h2v2h-2z",
          fill: "currentColor",
          opacity: 0.9
        })
      );
    }

    function apply(ctx) {
      ctx.slots.inject("main", () =>
        ctx.slots.register(
          {
            name: "main",
            key: PANEL_ID,
            inject: () => ({})
          },
          PairingPage
        )
      );
      ctx.slots.inject("sidebar.panellist", () =>
        ctx.slots.register(
          {
            name: "sidebar.panellist",
            id: PANEL_ID,
            order: 90,
            label: () => "配对"
          },
          PairingIcon
        )
      );
    }

    const inject = ["slots"];

    exports.apply = apply;
    exports.inject = inject;
    return module.exports;
  }
});
