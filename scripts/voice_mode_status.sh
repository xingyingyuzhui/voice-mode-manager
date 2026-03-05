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

show_one() {
  local name="$1"
  local pid_file="$2"

  if [[ ! -f "$pid_file" ]]; then
    echo "$name: down"
    return
  fi

  local pid
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "$name: up (pid=$pid)"
  else
    echo "$name: stale pid file"
  fi
}

show_one "TTS worker" "$TTS_WORKER_PID_FILE"
show_one "Voice loop" "$LOOP_PID_FILE"

if docker ps --format '{{.Names}}' | rg -q '^funasr-official$'; then
  echo "official runtime docker: up (funasr-official)"
elif docker ps -a --format '{{.Names}}' | rg -q '^funasr-official$'; then
  echo "official runtime docker: down (funasr-official exists)"
else
  echo "official runtime docker: missing (funasr-official)"
fi
