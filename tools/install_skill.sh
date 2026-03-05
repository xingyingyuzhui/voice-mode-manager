#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
WORKSPACE="${OPENCLAW_WORKSPACE:-$OPENCLAW_HOME/workspace}"
SKILL_DIR="$WORKSPACE/skills/voice-mode-manager"
VG_DIR="$WORKSPACE/voice-gateway"

mkdir -p "$SKILL_DIR/scripts" "$VG_DIR"

cp "$REPO_DIR/SKILL.md" "$SKILL_DIR/SKILL.md"
cp "$REPO_DIR/scripts/voice_mode_start.sh" "$SKILL_DIR/scripts/"
cp "$REPO_DIR/scripts/voice_mode_stop.sh" "$SKILL_DIR/scripts/"
cp "$REPO_DIR/scripts/voice_mode_status.sh" "$SKILL_DIR/scripts/"
chmod +x "$SKILL_DIR/scripts/"*.sh

cp "$REPO_DIR/runtime/voice-gateway/voice_assistant_official_runtime.py" "$VG_DIR/"
cp "$REPO_DIR/runtime/voice-gateway/tts_worker_mlx.py" "$VG_DIR/"
cp "$REPO_DIR/runtime/voice-gateway/requirements.txt" "$VG_DIR/"

if [[ ! -x "$VG_DIR/.venv/bin/python" ]]; then
  python3 -m venv "$VG_DIR/.venv"
fi
"$VG_DIR/.venv/bin/pip" install -U pip >/dev/null
"$VG_DIR/.venv/bin/pip" install -r "$VG_DIR/requirements.txt"

echo "Installed skill to: $SKILL_DIR"
echo "Runtime synced to: $VG_DIR"
echo "Next: bash $SKILL_DIR/scripts/voice_mode_start.sh"
