import json
import os
import shutil
import socket
import tempfile
import time
from pathlib import Path

from mlx_audio.tts.utils import load_model
from mlx_audio.tts.generate import generate_audio

SOCK_PATH = os.getenv("VOICE_TTS_WORKER_SOCK", "/tmp/voice_tts_worker.sock")
DEFAULT_MODEL = os.getenv("VOICE_TTS_MLX_MODEL", "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit")
DEFAULT_VOICE = os.getenv("VOICE_TTS_MLX_VOICE", "Vivian")
DEFAULT_LANG = os.getenv("VOICE_TTS_MLX_LANG", "zh")
DEFAULT_TEMPERATURE = float(os.getenv("VOICE_TTS_MLX_TEMPERATURE", "0.1"))
CLEANUP_OLDER_S = int(os.getenv("VOICE_TTS_TMP_CLEANUP_OLDER_S", "900"))


def cleanup_old_tmp_dirs():
    tmp_root = Path(tempfile.gettempdir())
    now = time.time()
    for d in tmp_root.glob("mlx_tts_worker_*"):
        if not d.is_dir():
            continue
        try:
            age = now - d.stat().st_mtime
            if age >= CLEANUP_OLDER_S:
                shutil.rmtree(d, ignore_errors=True)
        except Exception:
            pass


def synth_once(model, text: str, voice: str, lang_code: str, temperature: float) -> str:
    out_dir = Path(tempfile.mkdtemp(prefix="mlx_tts_worker_"))
    prefix = str(out_dir / "tts")
    generate_audio(
        model=model,
        text=text,
        voice=voice,
        lang_code=lang_code,
        temperature=temperature,
        file_prefix=prefix,
        audio_format="wav",
        verbose=False,
    )
    out = f"{prefix}_000.wav"
    if not os.path.exists(out):
        cands = sorted(out_dir.glob("tts_*.wav"))
        if not cands:
            raise RuntimeError("no wav generated")
        out = str(cands[0])
    return out


def main():
    if os.path.exists(SOCK_PATH):
        os.remove(SOCK_PATH)

    model = load_model(DEFAULT_MODEL)

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK_PATH)
    srv.listen(16)
    os.chmod(SOCK_PATH, 0o666)
    print(f"tts_worker ready: {SOCK_PATH}", flush=True)

    try:
        while True:
            cleanup_old_tmp_dirs()
            conn, _ = srv.accept()
            with conn:
                try:
                    buf = b""
                    while not buf.endswith(b"\n"):
                        chunk = conn.recv(4096)
                        if not chunk:
                            break
                        buf += chunk
                    if not buf:
                        continue
                    req = json.loads(buf.decode("utf-8").strip())
                    text = (req.get("text") or "").strip()
                    voice = req.get("voice") or DEFAULT_VOICE
                    lang_code = req.get("lang_code") or DEFAULT_LANG
                    if not text:
                        raise ValueError("empty text")
                    temperature = float(req.get("temperature", DEFAULT_TEMPERATURE))
                    wav = synth_once(model, text, voice, lang_code, temperature)
                    resp = {"ok": True, "wav": wav}
                except Exception as e:
                    resp = {"ok": False, "error": str(e)}
                conn.sendall((json.dumps(resp, ensure_ascii=False) + "\n").encode("utf-8"))
    finally:
        srv.close()
        if os.path.exists(SOCK_PATH):
            os.remove(SOCK_PATH)


if __name__ == "__main__":
    main()
