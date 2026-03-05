# AGENTS.md

This file is for automation agents that need to install and operate this skill without extra human context.

## Goal

Deploy `voice-mode-manager` into an existing OpenClaw environment and verify realtime voice chain is runnable.

## Preconditions

1. OS: macOS.
2. `openclaw` CLI is installed and available in `PATH`.
3. Docker is installed and daemon is running.
4. A FunASR runtime container named `funasr-official` exists (or can be created from official FunASR runtime docs).
5. Python3 is available.

Official links:
- OpenClaw: <https://github.com/openclaw/openclaw>
- FunASR: <https://github.com/modelscope/FunASR>
- FunASR runtime docs: <https://github.com/modelscope/FunASR/tree/main/runtime>
- MLX Audio: <https://github.com/Blaizzy/mlx-audio>
- Qwen3-TTS model: <https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit>

## Install steps (strict order)

1. Clone repo.
2. Run installer.
3. Run verifier.
4. Start skill.
5. Check status.

Commands:

```bash
git clone https://github.com/xingyingyuzhui/voice-mode-manager.git
cd voice-mode-manager
bash ./tools/install_skill.sh
bash ./tools/verify_setup.sh
bash ~/.openclaw/workspace/skills/voice-mode-manager/scripts/voice_mode_start.sh
bash ~/.openclaw/workspace/skills/voice-mode-manager/scripts/voice_mode_status.sh
```

## Required runtime env (minimum)

- `FUNASR_RUNTIME_SCHEME` (default: `wss`)
- `FUNASR_RUNTIME_HOST` (default: `127.0.0.1`)
- `FUNASR_RUNTIME_PORT` (default: `10095`)
- `VOICE_LLM_CMD` (default: `openclaw agent --agent main --message {text}`)

If custom paths are needed:

- `VOICE_WORKSPACE` or `OPENCLAW_WORKSPACE`
- `VOICE_GATEWAY_DIR`
- `VOICE_MLX_TTS_PY`

## Success criteria

1. `voice_mode_status.sh` shows voice loop process as up.
2. Docker `funasr-official` container is up.
3. `voice-gateway/logs/voice_loop_official.log` has `voice_connected` events.
4. A spoken utterance produces one `voice_turn_metrics` event.

## Failure handling

1. If `funasr-official` missing: stop and report exact command output.
2. If TTS worker socket missing: check `tts_worker.log`, report and stop.
3. If websocket health check fails: report host/port/scheme and stop.
4. Never modify OpenClaw core source; only manage this skill/runtime files.

## Safe rollback

```bash
bash ~/.openclaw/workspace/skills/voice-mode-manager/scripts/voice_mode_stop.sh
```

Then restore previous runtime files if a backup exists.
