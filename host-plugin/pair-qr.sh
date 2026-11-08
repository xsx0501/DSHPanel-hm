#!/usr/bin/env bash
# Print (or serve) a pairing QR for the currently running DSH host.
#
#   ./pair-qr.sh                     # endpoint from --trusted-host, QR in terminal
#   ./pair-qr.sh --url https://dsh.example.com
#   ./pair-qr.sh --svg out.svg       # file for a browser / printer
#   ./pair-qr.sh --link              # just the deep link
#
# The startup token is single-use: after the phone pairs with it, restart DSH to
# mint a fresh one (the phone keeps working on its own device token).
set -euo pipefail

# Termux hosts keep the log outside the proot home.
LOG_FILE="${LOG_FILE:-$( [ -f /data/data/com.termux/files/home/dsh.log ] && echo /data/data/com.termux/files/home/dsh.log || echo $HOME/dsh.log )}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
PROFILE="${PROFILE:-web}"
PORT="${PORT:-3080}"
PUBLIC_URL=""
OUT=""
ONLY_LINK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --url) PUBLIC_URL="$2"; shift ;;
    --log) LOG_FILE="$2"; shift ;;
    --port) PORT="$2"; shift ;;
    --svg) OUT="$2"; shift ;;
    --link) ONLY_LINK=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

TOKEN="$(grep -ao 'token=[A-Za-z0-9_-]\{8,\}' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
[ -n "$TOKEN" ] || { echo "no startup token in $LOG_FILE (is DSH running?)" >&2; exit 1; }

if [ -z "$PUBLIC_URL" ]; then
  HOST="$(grep -ao 'trusted-host [^ ]*' "$LOG_FILE" 2>/dev/null | tail -1 | awk '{print $2}' || true)"
  if [ -n "$HOST" ]; then
    PUBLIC_URL="https://$HOST"
  else
    PUBLIC_URL="http://127.0.0.1:$PORT"
  fi
fi

DEEP="dsh://connect?endpoint=$(printf %s "$PUBLIC_URL" | sed 's|:|%3A|g; s|/|%2F|g')&token=$TOKEN"
echo "endpoint:  $PUBLIC_URL"
echo "token:     ${TOKEN:0:8}…"
echo "deep link: $DEEP"
[ "$ONLY_LINK" = "1" ] && exit 0

if [ -n "$OUT" ]; then
  Q="$(printf %s "$DEEP" | sed 's|:|%3A|g; s|/|%2F|g; s|?|%3F|g; s|&|%26|g; s|=|%3D|g')"
  curl -fsS "http://127.0.0.1:$PORT/api/panel/qr?format=svg&data=$Q" -o "$OUT"
  echo "wrote $OUT"
  exit 0
fi

NODE_PATH="$DSH_HOME/profiles/$PROFILE/node_modules" node -e '
  import("qrcode-terminal").then((m) => {
    const q = m.default ?? m
    q.generate(process.argv[1], { small: true }, (art) => console.log(art))
  }).catch(() => console.error("(install qrcode-terminal for a terminal QR — the deep link above still works)"))
' "$DEEP"
