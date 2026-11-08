#!/usr/bin/env bash
# Install / upgrade the DSH panel bridge plugin, then print a pairing QR.
#
#   ./install.sh                       # install + patch (then restart DSH)
#   ./install.sh --no-restart          # install only
#   RESTART_CMD='...' ./install.sh     # run your own restart command
#   PUBLIC_URL=https://dsh.example.com ./install.sh
#   ./install.sh --uninstall           # remove every panel-bridge-* copy
#
# Facts this script encodes (learned the hard way):
#   * the loader wants `id: panel-bridge-N` + `name: ./plugins/panel-bridge-N/index.js`
#     (a package-style `name:` fails with ERR_MODULE_NOT_FOUND);
#   * `@` starts a reserved YAML scalar, so unquoted names break the whole profile;
#   * plugin files must sit FLAT in the directory next to index.js;
#   * on proot/Termux a restart started from inside the container dies with it.
set -euo pipefail

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
PROFILE="${PROFILE:-web}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="$DSH_HOME/profiles/$PROFILE/plugins"
PATCH_FILE="$DSH_HOME/profiles/$PROFILE/cordis.patch.yml"
# Termux hosts keep the log outside the proot home.
LOG_FILE="${LOG_FILE:-$( [ -f /data/data/com.termux/files/home/dsh.log ] && echo /data/data/com.termux/files/home/dsh.log || echo $HOME/dsh.log )}"
RESTART=1
UNINSTALL=0
PUBLIC_URL="${PUBLIC_URL:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-restart) RESTART=0 ;;
    --uninstall) UNINSTALL=1 ;;
    --profile) PROFILE="$2"
               PLUGINS_DIR="$DSH_HOME/profiles/$PROFILE/plugins"
               PATCH_FILE="$DSH_HOME/profiles/$PROFILE/cordis.patch.yml"
               shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '\033[36m[install]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[install] %s\033[0m\n' "$*" >&2; exit 1; }

[ -d "$PLUGINS_DIR" ] || die "plugins dir not found: $PLUGINS_DIR (is DSH_HOME right?)"
[ -f "$SELF_DIR/lib/index.js" ] || die "run this from the dsh-panel-bridge checkout"

PORT="$(grep -oE 'port: *[0-9]+' "$DSH_HOME/profiles/$PROFILE/cordis.yml" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)"
PORT="${PORT:-3080}"
[ -n "$PUBLIC_URL" ] || PUBLIC_URL="http://127.0.0.1:$PORT"

if [ "$UNINSTALL" = "1" ]; then
  say "removing panel-bridge plugin copies"
  rm -rf "$PLUGINS_DIR"/panel-bridge-*
  if [ -f "$PATCH_FILE" ]; then
    cp "$PATCH_FILE" "$PATCH_FILE.bak-uninstall-$(date +%Y%m%d-%H%M%S)"
    python3 "$SELF_DIR/tools/patch_profile.py" --remove || die "could not clean patch list"
  fi
  say "done; restart DSH to unload the plugin"
  exit 0
fi

# ---- copy into the next numbered directory (flat layout) --------------------
NEXT=1
for d in "$PLUGINS_DIR"/panel-bridge-*; do
  [ -d "$d" ] || continue
  n="${d##*/panel-bridge-}"
  case "$n" in ''|*[!0-9]*) continue ;; esac
  [ "$n" -ge "$NEXT" ] && NEXT=$((n + 1))
done
TARGET="$PLUGINS_DIR/panel-bridge-$NEXT"
mkdir -p "$TARGET"
cp "$SELF_DIR/lib/"*.js "$TARGET/"
cp "$SELF_DIR/package.json" "$TARGET/"
[ -f "$SELF_DIR/README.md" ] && cp "$SELF_DIR/README.md" "$TARGET/"
node --check "$TARGET/index.js" || die "index.js has a syntax error"
say "copied plugin to $TARGET"

# ---- patch the profile (idempotent, backed up, validated) -------------------
cp "$PATCH_FILE" "$PATCH_FILE.bak-panel-bridge-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
python3 "$SELF_DIR/tools/patch_profile.py" --patch "$PATCH_FILE" --plugins "$PLUGINS_DIR" \
  || die "profile patch failed (backup kept)"

# ---- restart ----------------------------------------------------------------
if [ "$RESTART" = "1" ]; then
  if [ -n "${RESTART_CMD:-}" ]; then
    say "restarting via RESTART_CMD"
    set +e; sh -c "$RESTART_CMD" >> "$LOG_FILE" 2>&1; set -e
  else
    say "restart DSH to mount the plugin, e.g.:"
    say "  ssh <host> \"nohup sh -c 'sh ~/panel-restart.sh' >/dev/null 2>&1 &\""
    say "  or: RESTART_CMD='systemctl restart dsh' ./install.sh"
  fi
  say "waiting for http://127.0.0.1:$PORT …"
  set +e
  for i in $(seq 1 90); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT/" || true)"
    case "$code" in 401|200) say "up after ${i}s (HTTP $code)"; break ;; esac
    sleep 2
  done
  set -e
fi

# ---- pairing QR -------------------------------------------------------------
TOKEN="$(grep -ao 'token=[A-Za-z0-9_-]\{8,\}' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
if [ -z "$TOKEN" ]; then
  say "no startup token in $LOG_FILE yet — run ./pair-qr.sh once DSH is up"
  exit 0
fi
DEEP="dsh://connect?endpoint=$(printf %s "$PUBLIC_URL" | sed 's|:|%3A|g; s|/|%2F|g')&token=$TOKEN"
say "endpoint: $PUBLIC_URL"
say "deep link: $DEEP"
say "browser QR: $PUBLIC_URL/api/panel/qr?data=$(printf %s "$DEEP" | sed 's|:|%3A|g; s|/|%2F|g; s|?|%3F|g; s|&|%26|g; s|=|%3D|g')"
NODE_PATH="$DSH_HOME/profiles/$PROFILE/node_modules" node -e '
  import("qrcode-terminal").then((m) => {
    const q = m.default ?? m
    q.generate(process.argv[1], { small: true }, (art) => console.log(art))
  }).catch(() => console.error("(install qrcode-terminal for a terminal QR — the link above still works)"))
' "$DEEP" || true
