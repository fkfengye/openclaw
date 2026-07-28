#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PID_FILE="$DIR/build/linux/.gateway.pid"

kill_gateway() {
  local pid=$1
  kill "$pid" 2>/dev/null || return 1
  for i in 1 2 3; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  kill -9 "$pid" 2>/dev/null || true
  return 0
}

# Try PID file first
if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE")
  if kill -0 "$PID" 2>/dev/null; then
    kill_gateway "$PID"
    echo "Gateway stopped (PID: $PID)"
    rm -f "$PID_FILE"
    exit 0
  fi
  rm -f "$PID_FILE"
fi

# Fallback: find by port
PID=$(fuser 18789/tcp 2>/dev/null | awk '{print $1}' || true)
if [ -n "$PID" ]; then
  kill_gateway "$PID"
  echo "Gateway stopped (PID: $PID)"
  exit 0
fi

echo "Gateway is not running"
