#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
WORKSPACE="${OPENCLAW_WORKSPACE:-$OPENCLAW_HOME/workspace}"
SKILL_DIR="$WORKSPACE/skills/voice-mode-manager"
VG_DIR="$WORKSPACE/voice-gateway"

check() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd"; then
    echo "[OK] $name"
  else
    echo "[FAIL] $name"
    return 1
  fi
}

check "skill files" "test -f '$SKILL_DIR/SKILL.md' && test -x '$SKILL_DIR/scripts/voice_mode_start.sh'"
check "runtime files" "test -f '$VG_DIR/voice_assistant_official_runtime.py' && test -f '$VG_DIR/tts_worker_mlx.py'"
check "runtime venv" "test -x '$VG_DIR/.venv/bin/python'"
check "docker funasr-official exists" "docker ps -a --format '{{.Names}}' | rg -q '^funasr-official$'"

echo "Run: bash $SKILL_DIR/scripts/voice_mode_start.sh"
