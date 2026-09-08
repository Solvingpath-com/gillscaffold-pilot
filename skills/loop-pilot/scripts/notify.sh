#!/usr/bin/env bash
# loop-pilot notify — push a message to the owner's phone. Called by loop.sh at endings
# (COMPLETE / INCOMPLETE), recorded defects, and fleet pauses. Silent no-op if unconfigured.
#
# Setup (~/.loop-pilot/notify.env):
#   TELEGRAM_BOT_TOKEN=123456:ABC...     # @BotFather → /newbot; then message your bot once
#   TELEGRAM_CHAT_ID=987654321           # get it: curl api.telegram.org/bot<TOKEN>/getUpdates
#   WEBHOOK_URL=https://...              # optional: any JSON endpoint (Slack, Gallabox relay)
#
# Usage:
#   notify.sh "<title>" "<body>"
#   notify.sh --test          send a test message and report configured channels
set -uo pipefail

CFG="${LOOP_PILOT_STATE:-$HOME/.loop-pilot}/notify.env"
[ -f "$CFG" ] && . "$CFG"

TITLE="${1:-}"; BODY="${2:-}"
if [ "$TITLE" = "--test" ]; then
  TITLE="loop-pilot test"; BODY="Notifications are wired up. $(date '+%Y-%m-%d %H:%M')"
  TEST=1
else
  TEST=0
fi
[ -z "$TITLE" ] && { echo "usage: notify.sh <title> <body> | --test"; exit 1; }

sent=0
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  curl -s -m 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${TITLE}
${BODY}" >/dev/null 2>&1 && { sent=$((sent+1)); [ "$TEST" = 1 ] && echo "telegram: sent"; }
fi
if [ -n "${WEBHOOK_URL:-}" ]; then
  python3 - "$WEBHOOK_URL" "$TITLE" "$BODY" <<'PY' >/dev/null 2>&1 && { sent=$((sent+1)); [ "$TEST" = 1 ] && echo "webhook: sent"; }
import json,sys,urllib.request
url,title,body=sys.argv[1:4]
req=urllib.request.Request(url,data=json.dumps({"title":title,"text":f"{title}\n{body}"}).encode(),
                           headers={"Content-Type":"application/json"})
urllib.request.urlopen(req,timeout=10)
PY
fi

if [ "$TEST" = 1 ]; then
  [ "$sent" -eq 0 ] && echo "no channels configured — create $CFG (see header of this script)"
fi
exit 0
