---
name: voice-mode-manager
description: Start, stop, and inspect local realtime voice mode pipeline (ASR + LLM bridge + TTS) for this workspace. Use when the user says phrases like "启动语音模式", "语音模式结束", "语音模式状态", or asks to keep voice services resident/hot for low latency and release them on demand.
---

# Voice Mode Manager

Use scripts in `scripts/` to manage resident voice-mode processes safely.

## Run commands

- Start voice mode:
  - `bash "${OPENCLAW_HOME:-$HOME/.openclaw}/workspace/skills/voice-mode-manager/scripts/voice_mode_start.sh"`
- Stop voice mode:
  - `bash "${OPENCLAW_HOME:-$HOME/.openclaw}/workspace/skills/voice-mode-manager/scripts/voice_mode_stop.sh"`
- Check status:
  - `bash "${OPENCLAW_HOME:-$HOME/.openclaw}/workspace/skills/voice-mode-manager/scripts/voice_mode_status.sh"`

The scripts auto-detect workspace paths from their own location. Optional overrides:
- `VOICE_WORKSPACE` / `OPENCLAW_WORKSPACE`
- `VOICE_GATEWAY_DIR`
- `VOICE_MLX_TTS_PY`

## Behavior

- Official ASR flow only: always use `voice_assistant_official_runtime.py`.
- Start script requires Docker container `funasr-official`; missing container causes startup failure.
- Start script keeps runtime docker, TTS worker, and voice loop resident for low latency.
- Default TTS backend is MLX (`VOICE_TTS_BACKEND=mlx`) with isolated env.
- Keep rollback path available via `VOICE_TTS_BACKEND=pytorch`.
- Official runtime defaults are:
  - `FUNASR_RUNTIME_SCHEME=wss`
  - `FUNASR_RUNTIME_HOST=127.0.0.1`
  - `FUNASR_RUNTIME_PORT=10095`
- Reply style control is text-driven (non-explicit TTS params):
  - Set `VOICE_REPLY_STYLE_HINT` to guide tone/rhythm for each assistant reply.
  - The runtime appends this hint to the message before calling `openclaw agent`.
- Use status script after start/stop and report concise state to user.

## Runtime knobs (optional env)

- `VOICE_CHUNK_MS` (default `60`)
- `VOICE_BARGE_RMS` (default `0.012`)
- `VOICE_VAD_RMS` (default `0.008`)
- `VOICE_FINALIZE_MIN_GAP_S` (default `1.0`)
- `VOICE_FINALIZE_STABLE_S` (default `1.2`)
- `VOICE_FINALIZE_TIMEOUT_S` (default `8.0`)
- `VOICE_FINALIZE_MIN_LEN` (default `8`)
- `VOICE_REPLY_STYLE_HINT` (default: stable, concise, neutral-warm Chinese speech style)

## Notes

- Scripts use PID files under `voice-gateway/.run/`.
- Logs are written under `voice-gateway/logs/`.
- If start detects already-running processes, it does not duplicate them.
