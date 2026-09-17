#!/usr/bin/env python3
"""Opt-in, real native-model smoke test. No microphone or network needed.

Usage: python3 tests/roundtrip.py /path/to/voice-runtime
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import wave

root = Path(sys.argv[1]).resolve()
suffix = ".exe" if sys.platform == "win32" else ""
model = root / "models" / "kokoro"
with tempfile.TemporaryDirectory(prefix="moked-voice-smoke-") as temporary:
    target = Path(temporary)
    audio = target / "fr.wav"
    # A leading space prevents a message from being interpreted as CLI options.
    sentence = " Bonjour, votre équipe peut organiser les missions et préparer les documents."
    started = time.monotonic()
    synth = subprocess.run([
        str(root / "sherpa" / "bin" / ("sherpa-onnx-offline-tts" + suffix)),
        f"--kokoro-model={model / 'model.int8.onnx'}", f"--kokoro-voices={model / 'voices.bin'}",
        f"--kokoro-tokens={model / 'tokens.txt'}", f"--kokoro-data-dir={model / 'espeak-ng-data'}",
        "--kokoro-lang=fr", "--sid=30", "--num-threads=2", "--debug=0", f"--output-filename={audio}", sentence,
    ], capture_output=True, timeout=120)
    if synth.returncode:
        raise RuntimeError("Kokoro failed: " + synth.stderr.decode(errors="replace")[-2000:])
    elapsed = time.monotonic() - started
    with wave.open(str(audio), "rb") as stream:
        seconds = stream.getnframes() / stream.getframerate()
        assert stream.getframerate() == 24000 and seconds > 1
    stt = subprocess.run([
        str(root / "bin" / ("whisper-cli" + suffix)), "-m", str(root / "models" / "ggml-base-q5_1.bin"),
        "-f", str(audio), "-l", "auto", "-t", "4", "-oj", "-of", str(target / "transcript"), "-np", "-nt",
    ], capture_output=True, timeout=120)
    if stt.returncode:
        raise RuntimeError("Whisper failed: " + stt.stderr.decode(errors="replace")[-2000:])
    result = json.loads((target / "transcript.json").read_text())
    text = " ".join(segment["text"] for segment in result["transcription"]).lower()
    assert result["result"]["language"] == "fr", result
    assert "missions" in text and "documents" in text, text
    print(json.dumps({"language": "fr", "audio_seconds": round(seconds, 2), "tts_wall_seconds": round(elapsed, 2), "result": "passed"}))
