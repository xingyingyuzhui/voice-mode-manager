import asyncio
import json
import os
import queue
import shutil
import socket
import shlex
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf
import ssl
import websockets

SR = 16000
CH = 1
CHUNK_MS = int(os.getenv("VOICE_CHUNK_MS", "60"))  # align with FunASR client default chunk pacing
RUNTIME_HOST = os.getenv("FUNASR_RUNTIME_HOST", "127.0.0.1")
RUNTIME_PORT = int(os.getenv("FUNASR_RUNTIME_PORT", "10095"))
RUNTIME_SCHEME = os.getenv("FUNASR_RUNTIME_SCHEME", "wss")
INPUT_DEVICE = os.getenv("VOICE_INPUT_DEVICE")
OUTPUT_DEVICE = os.getenv("VOICE_OUTPUT_DEVICE")

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_WORKSPACE = SCRIPT_DIR.parent
WORKSPACE = Path(
    os.getenv("VOICE_WORKSPACE")
    or os.getenv("OPENCLAW_WORKSPACE")
    or str(DEFAULT_WORKSPACE)
).expanduser().resolve()
QWEN_PY = Path(os.getenv("VOICE_QWEN_PY", str(WORKSPACE / "qwen-venv/bin/python")))
QWEN_TTS_SCRIPT = Path(
    os.getenv("VOICE_QWEN_TTS_SCRIPT", str(WORKSPACE / "skills/qwen3-tts-local/scripts/tts_customvoice.py"))
)
MLX_TTS_PY = Path(os.getenv("VOICE_MLX_TTS_PY", str(WORKSPACE / "experiments/mlx-tts/.venv/bin/python")))
MLX_TTS_MODEL = os.getenv("VOICE_TTS_MLX_MODEL", "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit")
TTS_WORKER_SOCK = os.getenv("VOICE_TTS_WORKER_SOCK", "/tmp/voice_tts_worker.sock")

q = queue.Queue()


def log_event(event: str, **kwargs):
    payload = {"event": event, "ts": round(time.time(), 3)}
    payload.update(kwargs)
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def cb(indata, frames, time_info, status):
    mono = np.clip(indata[:, 0], -1, 1)
    pcm16 = (mono * 32767).astype(np.int16).tobytes()
    q.put(pcm16)


def _clean_text(text: str) -> str:
    import re
    text = re.sub(r"<\|[^|]+\|>", "", text or "")
    return text.strip()


def llm_reply(text: str) -> tuple[str, float]:
    text = _clean_text(text)
    if not text:
        return "我没听清，再说一遍。", 0.0
    style_hint = os.getenv("VOICE_REPLY_STYLE_HINT", "").strip()
    payload = text
    if style_hint:
        payload = f"{text}\n\n[语音回复风格要求]\n{style_hint}"
    cmd_tpl = os.getenv("VOICE_LLM_CMD", 'openclaw agent --agent main --message {text}').strip()
    if not cmd_tpl:
        return f"收到：{text}", 0.0
    try:
        placeholder = "__VOICE_TEXT_PLACEHOLDER__"
        if "{text}" in cmd_tpl:
            argv = shlex.split(cmd_tpl.replace("{text}", placeholder))
            argv = [payload if token == placeholder else token for token in argv]
        else:
            argv = shlex.split(cmd_tpl)
        t0 = time.perf_counter()
        p = subprocess.run(argv, shell=False, capture_output=True, text=True, timeout=45, cwd=str(WORKSPACE))
        llm_ms = (time.perf_counter() - t0) * 1000.0
        out = (p.stdout or "").strip()
        lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
        return (lines[-1] if lines else f"收到：{text}"), llm_ms
    except Exception:
        return f"收到：{text}", 0.0


def _tts_worker_request(text: str) -> str:
    req = {
        "text": text,
        "voice": os.getenv("VOICE_TTS_MLX_VOICE", "Vivian"),
        "lang_code": os.getenv("VOICE_TTS_MLX_LANG", "zh"),
        "temperature": float(os.getenv("VOICE_TTS_MLX_TEMPERATURE", "0.1")),
        "model": MLX_TTS_MODEL,
    }
    timeout_s = float(os.getenv("VOICE_TTS_TIMEOUT_S", "30"))
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout_s)
        s.connect(TTS_WORKER_SOCK)
        s.sendall((json.dumps(req, ensure_ascii=False) + "\n").encode("utf-8"))
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
    if not data:
        raise RuntimeError("TTS worker returned empty response")
    resp = json.loads(data.decode("utf-8").strip())
    if not resp.get("ok"):
        raise RuntimeError(resp.get("error") or "TTS worker failed")
    return resp["wav"]


def synth_to_wav(text: str, speaker: str = "serena") -> str:
    backend = os.getenv("VOICE_TTS_BACKEND", "mlx").strip().lower()

    if backend == "mlx":
        use_worker = os.getenv("VOICE_TTS_USE_WORKER", "1") == "1"
        if use_worker and os.path.exists(TTS_WORKER_SOCK):
            try:
                return _tts_worker_request(text)
            except Exception as e:
                print(f"[tts_worker_fallback] {e}")

        mlx_voice = os.getenv("VOICE_TTS_MLX_VOICE", "Vivian")
        mlx_lang = os.getenv("VOICE_TTS_MLX_LANG", "zh")
        out_dir = Path(tempfile.mkdtemp(prefix="mlx_tts_"))
        prefix = str(out_dir / "tts")
        cmd = [
            str(MLX_TTS_PY),
            "-m",
            "mlx_audio.tts.generate",
            "--model",
            MLX_TTS_MODEL,
            "--text",
            text,
            "--voice",
            mlx_voice,
            "--lang_code",
            mlx_lang,
            "--file_prefix",
            prefix,
            "--audio_format",
            "wav",
        ]
        subprocess.run(cmd, check=True, cwd=str(WORKSPACE))
        out = f"{prefix}_000.wav"
        if not os.path.exists(out):
            cands = sorted(out_dir.glob("tts_*.wav"))
            if not cands:
                raise RuntimeError("MLX TTS produced no wav output")
            out = str(cands[0])
        return out

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        out = f.name
    cmd = [
        str(QWEN_PY), str(QWEN_TTS_SCRIPT),
        "--text", text,
        "--speaker", speaker,
        "--out", out,
    ]
    subprocess.run(cmd, check=True, cwd=str(WORKSPACE))
    return out


async def main():
    uri = f"{RUNTIME_SCHEME}://{RUNTIME_HOST}:{RUNTIME_PORT}"
    wav_name = f"live-{uuid.uuid4().hex[:8]}"
    state = {
        "is_speaking": False,
        "speak_task": None,
        "last_offline": "",
        "reconnect_count": 0,
        "barge_in_count": 0,
    }

    ssl_ctx = None
    if RUNTIME_SCHEME == "wss":
        ssl_ctx = ssl.create_default_context()
        ssl_ctx.check_hostname = False
        ssl_ctx.verify_mode = ssl.CERT_NONE

    async with websockets.connect(
        uri,
        subprotocols=["binary"],
        ping_interval=None,
        max_size=8 * 1024 * 1024,
        ssl=ssl_ctx,
    ) as ws:
        init_msg = {
            "mode": "2pass",
            "wav_name": wav_name,
            "is_speaking": True,
            "wav_format": "pcm",
            "audio_fs": SR,
            "chunk_size": [8, 8, 4],
            "chunk_interval": 10,
            "itn": True,
        }
        await ws.send(json.dumps(init_msg, ensure_ascii=False))
        log_event("voice_connected", uri=uri, wav_name=wav_name)

        async def speak(reply: str, turn_id: str, asr_ms: float, llm_ms: float, t0: float):
            wav = None
            tts_ms = 0.0
            try:
                state["is_speaking"] = True
                t_tts = time.perf_counter()
                wav = await asyncio.to_thread(synth_to_wav, reply)
                tts_ms = (time.perf_counter() - t_tts) * 1000.0
                data, sr = sf.read(wav, dtype="float32")
                out_dev = int(OUTPUT_DEVICE) if OUTPUT_DEVICE and OUTPUT_DEVICE.isdigit() else (OUTPUT_DEVICE or None)
                await asyncio.to_thread(sd.play, data, sr, device=out_dev)
                await asyncio.to_thread(sd.wait)
            finally:
                state["is_speaking"] = False
                if wav and os.path.exists(wav):
                    try:
                        os.remove(wav)
                    except Exception:
                        pass
                if wav:
                    parent = Path(wav).parent
                    if parent.name.startswith("mlx_tts_") or parent.name.startswith("mlx_tts_worker_"):
                        shutil.rmtree(parent, ignore_errors=True)
                e2e_ms = (time.perf_counter() - t0) * 1000.0
                log_event(
                    "voice_turn_metrics",
                    turn_id=turn_id,
                    asr_ms=round(asr_ms, 1),
                    llm_ms=round(llm_ms, 1),
                    tts_ms=round(tts_ms, 1),
                    e2e_ms=round(e2e_ms, 1),
                    reconnect_count=state["reconnect_count"],
                    barge_in_count=state["barge_in_count"],
                )

        async def recv_loop():
            while True:
                raw = await ws.recv()
                if not isinstance(raw, str):
                    continue
                msg = json.loads(raw)
                mode = msg.get("mode", "")
                text = _clean_text(msg.get("text", ""))
                if not text:
                    continue

                if mode == "2pass-online":
                    log_event("voice_asr_online", text=text[:120])
                elif mode in ("2pass-offline", "offline"):
                    t0 = time.perf_counter()
                    log_event("voice_asr_offline", text=text[:200])
                    if text == state["last_offline"]:
                        continue
                    state["last_offline"] = text
                    reply, llm_ms = await asyncio.to_thread(llm_reply, text)
                    asr_ms = (time.perf_counter() - t0) * 1000.0
                    log_event("voice_assistant_reply", text=reply[:200])
                    if state.get("speak_task") and not state["speak_task"].done():
                        state["barge_in_count"] += 1
                        state["speak_task"].cancel()
                    turn_id = f"{int(time.time() * 1000)}-{uuid.uuid4().hex[:6]}"
                    state["speak_task"] = asyncio.create_task(speak(reply, turn_id, asr_ms, llm_ms, t0))

        recv_task = asyncio.create_task(recv_loop())

        blocksize = int(SR * CHUNK_MS / 1000)
        dev = int(INPUT_DEVICE) if INPUT_DEVICE and INPUT_DEVICE.isdigit() else (INPUT_DEVICE or None)
        log_event("voice_recording", input_device=(dev if dev is not None else "default"))

        with sd.InputStream(channels=CH, samplerate=SR, blocksize=blocksize, callback=cb, dtype="float32", device=dev):
            try:
                while True:
                    pcm = await asyncio.to_thread(q.get)
                    await ws.send(pcm)
                    await asyncio.sleep(0.01)
            except KeyboardInterrupt:
                pass

        await ws.send(json.dumps({"is_speaking": False}))
        await asyncio.sleep(1)
        recv_task.cancel()


if __name__ == "__main__":
    asyncio.run(main())
