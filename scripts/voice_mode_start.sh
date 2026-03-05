#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_WORKSPACE="$(cd "$SKILL_DIR/../.." && pwd)"
WORKSPACE="${VOICE_WORKSPACE:-${OPENCLAW_WORKSPACE:-$DEFAULT_WORKSPACE}}"
VG="${VOICE_GATEWAY_DIR:-$WORKSPACE/voice-gateway}"
MLX_TTS_PY="${VOICE_MLX_TTS_PY:-$WORKSPACE/experiments/mlx-tts/.venv/bin/python}"
RUN_DIR="$VG/.run"
LOG_DIR="$VG/logs"
mkdir -p "$RUN_DIR" "$LOG_DIR"

LOOP_PID_FILE="$RUN_DIR/voice_loop.pid"
TTS_WORKER_PID_FILE="$RUN_DIR/tts_worker.pid"
HEALTH_TIMEOUT_S="${VOICE_HEALTH_TIMEOUT_S:-12}"

is_running() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

start_tts_worker() {
  if [[ "${VOICE_TTS_BACKEND:-mlx}" != "mlx" ]]; then
    echo "TTS worker skipped (backend=${VOICE_TTS_BACKEND:-pytorch})"
    return
  fi

  if [[ -f "$TTS_WORKER_PID_FILE" ]]; then
    local pid
    pid=$(cat "$TTS_WORKER_PID_FILE" 2>/dev/null || true)
    if is_running "$pid"; then
      echo "TTS worker already running: $pid"
      return
    fi
  fi

  (
    cd "$VG"
    export VOICE_TTS_WORKER_SOCK="${VOICE_TTS_WORKER_SOCK:-/tmp/voice_tts_worker.sock}"
    export VOICE_TTS_MLX_MODEL="${VOICE_TTS_MLX_MODEL:-mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit}"
    export VOICE_TTS_MLX_VOICE="${VOICE_TTS_MLX_VOICE:-Vivian}"
    export VOICE_TTS_MLX_LANG="${VOICE_TTS_MLX_LANG:-zh}"
    export VOICE_TTS_MLX_TEMPERATURE="${VOICE_TTS_MLX_TEMPERATURE:-0.1}"
    if [[ ! -x "$MLX_TTS_PY" ]]; then
      echo "MLX TTS python not found: $MLX_TTS_PY"
      echo "Set VOICE_MLX_TTS_PY to a valid interpreter path."
      exit 1
    fi
    nohup "$MLX_TTS_PY" tts_worker_mlx.py >>"$LOG_DIR/tts_worker.log" 2>&1 &
    echo $! >"$TTS_WORKER_PID_FILE"
  )
  echo "TTS worker started: $(cat "$TTS_WORKER_PID_FILE")"
}

wait_for_tts_worker() {
  local elapsed=0
  while [[ "$elapsed" -lt "$HEALTH_TIMEOUT_S" ]]; do
    [[ -S "${VOICE_TTS_WORKER_SOCK:-/tmp/voice_tts_worker.sock}" ]] && return 0
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

start_loop() {
  if [[ -f "$LOOP_PID_FILE" ]]; then
    local pid
    pid=$(cat "$LOOP_PID_FILE" 2>/dev/null || true)
    if is_running "$pid"; then
      echo "voice loop already running: $pid"
      return
    fi
  fi

  (
    cd "$VG"
    # TTS backend (mlx default; rollback: pytorch)
    export VOICE_TTS_BACKEND="${VOICE_TTS_BACKEND:-mlx}"
    export VOICE_TTS_MLX_MODEL="${VOICE_TTS_MLX_MODEL:-mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit}"
    export VOICE_TTS_MLX_VOICE="${VOICE_TTS_MLX_VOICE:-Vivian}"
    export VOICE_TTS_MLX_LANG="${VOICE_TTS_MLX_LANG:-zh}"
    export VOICE_TTS_MLX_TEMPERATURE="${VOICE_TTS_MLX_TEMPERATURE:-0.1}"
    export VOICE_TTS_USE_WORKER="${VOICE_TTS_USE_WORKER:-1}"
    export VOICE_TTS_WORKER_SOCK="${VOICE_TTS_WORKER_SOCK:-/tmp/voice_tts_worker.sock}"
    export VOICE_REPLY_STYLE_HINT="${VOICE_REPLY_STYLE_HINT:-请用自然口语、简短句式回复；语气稳定克制，避免夸张语气词和连续感叹号；默认中性偏温和。}"

    # Streaming/latency knobs
    export VOICE_CHUNK_MS="${VOICE_CHUNK_MS:-60}"
    export VOICE_BARGE_RMS="${VOICE_BARGE_RMS:-0.012}"
    export VOICE_VAD_RMS="${VOICE_VAD_RMS:-0.008}"
    export VOICE_FINALIZE_MIN_GAP_S="${VOICE_FINALIZE_MIN_GAP_S:-1.0}"
    export VOICE_FINALIZE_STABLE_S="${VOICE_FINALIZE_STABLE_S:-1.2}"
    export VOICE_FINALIZE_TIMEOUT_S="${VOICE_FINALIZE_TIMEOUT_S:-8.0}"
    export VOICE_FINALIZE_MIN_LEN="${VOICE_FINALIZE_MIN_LEN:-8}"
    nohup ./.venv/bin/python voice_assistant_official_runtime.py >>"$LOG_DIR/voice_loop_official.log" 2>&1 &
    echo $! >"$LOOP_PID_FILE"
  )
  echo "voice loop(official) started: $(cat "$LOOP_PID_FILE")"
}

check_runtime_ws() {
  "$VG/.venv/bin/python" - <<'PY'
import asyncio
import json
import os
import ssl
import uuid
import websockets

scheme = os.getenv("FUNASR_RUNTIME_SCHEME", "wss")
host = os.getenv("FUNASR_RUNTIME_HOST", "127.0.0.1")
port = int(os.getenv("FUNASR_RUNTIME_PORT", "10095"))
uri = f"{scheme}://{host}:{port}"
ssl_ctx = None
if scheme == "wss":
    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE

async def probe():
    async with websockets.connect(uri, subprotocols=["binary"], ping_interval=None, max_size=8 * 1024 * 1024, ssl=ssl_ctx) as ws:
        init_msg = {
            "mode": "2pass",
            "wav_name": f"probe-{uuid.uuid4().hex[:8]}",
            "is_speaking": False,
            "wav_format": "pcm",
            "audio_fs": 16000,
            "chunk_size": [8, 8, 4],
            "chunk_interval": 10,
            "itn": True,
        }
        await ws.send(json.dumps(init_msg, ensure_ascii=False))
        await asyncio.sleep(0.01)
        return init_msg

asyncio.run(probe())
PY
}

# Official-only ASR path.
export FUNASR_RUNTIME_HOST="${FUNASR_RUNTIME_HOST:-127.0.0.1}"
export FUNASR_RUNTIME_PORT="${FUNASR_RUNTIME_PORT:-10095}"
export FUNASR_RUNTIME_SCHEME="${FUNASR_RUNTIME_SCHEME:-wss}"

if docker ps --format '{{.Names}}' | rg -q '^funasr-official$'; then
  echo "official runtime docker already running: funasr-official"
elif docker ps -a --format '{{.Names}}' | rg -q '^funasr-official$'; then
  docker start funasr-official >/dev/null
  echo "official runtime docker started: funasr-official"
else
  echo "official runtime docker not found: funasr-official"
  echo "Please create it first (full official 2pass deployment)."
  exit 1
fi

start_tts_worker
start_loop

# Health checks: loop pid, tts socket, runtime websocket.
if ! is_running "$(cat "$LOOP_PID_FILE" 2>/dev/null || true)"; then
  echo "voice loop failed to stay alive"
  exit 1
fi
if ! wait_for_tts_worker; then
  echo "tts worker socket not ready within ${HEALTH_TIMEOUT_S}s"
  exit 1
fi
if ! check_runtime_ws; then
  echo "runtime websocket health check failed"
  exit 1
fi

echo "voice mode: ON (asr_mode=official, tts_backend=${VOICE_TTS_BACKEND:-mlx})"
