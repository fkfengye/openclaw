#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

"$DIR/stop.sh"
sleep 1
"$DIR/start.sh"
