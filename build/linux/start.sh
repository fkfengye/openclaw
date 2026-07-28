#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="$HOME/.local/node/bin:$HOME/.local/share/pnpm:$PATH"
export OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-mytoken123}"

PID_FILE="$DIR/build/linux/.gateway.pid"
LOG_FILE="$DIR/build/linux/gateway.log"

mkdir -p "$(dirname "$PID_FILE")"

if fuser 18789/tcp >/dev/null 2>&1; then
  echo "Gateway is already running (port 18789 in use)"
  fuser 18789/tcp 2>/dev/null | awk '{print "PID: "$1}'
  exit 1
fi

cd "$DIR"
nohup pnpm openclaw gateway run --force --allow-unconfigured --bind lan \
  > "$LOG_FILE" 2>&1 &

for i in $(seq 1 15); do
  sleep 1
  PID=$(fuser 18789/tcp 2>/dev/null | awk '{print $1}' || true)
  if [ -n "$PID" ]; then
    echo "$PID" > "$PID_FILE"
    echo "Gateway started (PID: $PID)"
    echo "Web UI: http://localhost:18789"
    exit 0
  fi
done

echo "Gateway failed to start. Check log: $LOG_FILE"
exit 1
