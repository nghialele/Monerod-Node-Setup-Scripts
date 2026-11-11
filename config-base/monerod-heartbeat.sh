#!/usr/bin/env bash
# Monerod heartbeat: pokes the node's RPC every 30 seconds.
# If the node stops answering, it counts to five, then gives monerod a gentle
# (systemctl) shove. Five misses in a row means something is actually wrong.
set -u

STATE_FILE="/run/monerod-heartbeat.failcount"
URL="http://127.0.0.1:18089/get_height"
SERVICE="monerod"
MAX_FAILS=5

# If monerod is not running, reset counter and exit. Nothing to poke.
if ! systemctl is-active --quiet "$SERVICE"; then
    echo 0 > "$STATE_FILE"
    exit 0
fi

failcount=0
if [[ -f "$STATE_FILE" ]]; then
    failcount=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
fi

# Try RPC with a hard 50 second timeout. Patience is a virtue; 50s is the limit.
if curl --silent --show-error --fail --max-time 50 "$URL" >/dev/null; then
    echo 0 > "$STATE_FILE"
    exit 0
fi

failcount=$((failcount + 1))
echo "$failcount" > "$STATE_FILE"

logger -t monerod-heartbeat "monerod RPC heartbeat failed ${failcount}/${MAX_FAILS}"

if (( failcount >= MAX_FAILS )); then
    logger -t monerod-heartbeat "restarting monerod after ${failcount} consecutive RPC failures"
    echo 0 > "$STATE_FILE"
    systemctl restart "$SERVICE"
fi
