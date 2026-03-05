#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_WORKSPACE="$(cd "$SKILL_DIR/../.." && pwd)"
WORKSPACE="${VOICE_WORKSPACE:-${OPENCLAW_WORKSPACE:-$DEFAULT_WORKSPACE}}"
VG="${VOICE_GATEWAY_DIR:-$WORKSPACE/voice-gateway}"
RUN_DIR="$VG/.run"

LOOP_PID_FILE="$RUN_DIR/voice_loop.pid"
TTS_WORKER_PID_FILE="$RUN_DIR/tts_worker.pid"

stop_by_pidfile() {
  local name="$1"
  local pid_file="$2"

  if [[ ! -f "$pid_file" ]]; then
    echo "$name not running (no pid file)"
    return
  fi

  local pid
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [[ -z "$pid" ]]; then
    rm -f "$pid_file"
    echo "$name pid empty, cleaned"
    return
  fi

  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 0.5
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
    echo "$name stopped: $pid"
  else
    echo "$name not running: $pid"
  fi

  rm -f "$pid_file"
}

stop_by_pidfile "voice loop" "$LOOP_PID_FILE"
stop_by_pidfile "TTS worker" "$TTS_WORKER_PID_FILE"

# Official flow default: also stop docker runtime unless user disables it.
if [[ "${VOICE_STOP_OFFICIAL_DOCKER:-1}" == "1" ]]; then
  if docker ps --format '{{.Names}}' | rg -q '^funasr-official$'; then
    docker stop funasr-official >/dev/null || true
    echo "official runtime docker stopped: funasr-official"
  fi
fi

echo "voice mode: OFF"
