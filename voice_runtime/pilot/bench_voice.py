#!/usr/bin/env python3
"""Pilot latency bench: Kokoro ONNX TTS + faster-whisper STT (host, no Docker)."""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import time
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"
PILOT_OUT = ROOT / "pilot" / "out"
SAMPLE_TEXT = "Two plus two equals four. That's a basic math fact."


def _ensure_dirs() -> None:
    DATA.mkdir(parents=True, exist_ok=True)
    PILOT_OUT.mkdir(parents=True, exist_ok=True)


def _download_kokoro_assets() -> tuple[Path, Path]:
    """Download Kokoro v1.0 ONNX + voices if missing (huggingface_hub)."""
    from huggingface_hub import hf_hub_download

    model = Path(
        hf_hub_download(
            repo_id="hexgrad/Kokoro-82M",
            filename="kokoro-v1.0.onnx",
            local_dir=str(DATA / "kokoro"),
        )
    )
    # voices.bin lives in kokoro-onnx releases / hexgrad — try common layouts
    voices_candidates = [
        DATA / "kokoro" / "voices.bin",
        DATA / "kokoro" / "voices" / "af_heart.bin",
    ]
    for c in voices_candidates:
        if c.exists():
            return model, c if c.name == "voices.bin" else c.parent

    # Official kokoro-onnx ships voices.bin via its own release assets
    voices = Path(
        hf_hub_download(
            repo_id="hexgrad/Kokoro-82M",
            filename="voices/af_heart.pt",
            local_dir=str(DATA / "kokoro"),
        )
    )
    return model, voices.parent


def bench_kokoro(text: str) -> dict:
    from kokoro_onnx import Kokoro

    model_path = DATA / "kokoro" / "kokoro-v1.0.onnx"
    voices_path = DATA / "kokoro" / "voices-v1.0.bin"
    if not model_path.exists() or not voices_path.exists():
        raise FileNotFoundError(
            f"Missing Kokoro assets. Expected {model_path} and {voices_path}. "
            "Run with --download first."
        )

    t0 = time.perf_counter()
    kokoro = Kokoro(str(model_path), str(voices_path))
    load_s = time.perf_counter() - t0

    t1 = time.perf_counter()
    samples, sample_rate = kokoro.create(text, voice="af_heart", speed=1.0, lang="en-us")
    synth_s = time.perf_counter() - t1

    out = PILOT_OUT / "kokoro_pilot.wav"
    import numpy as np

    audio = np.asarray(samples)
    if audio.dtype != np.int16:
        # float [-1,1] → int16
        audio_i16 = (audio * 32767.0).astype("int16")
    else:
        audio_i16 = audio
    with wave.open(str(out), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(audio_i16.tobytes())

    duration_s = len(audio_i16) / float(sample_rate)
    rtf = synth_s / duration_s if duration_s > 0 else None
    return {
        "engine": "kokoro-onnx",
        "voice": "af_heart",
        "text": text,
        "load_s": round(load_s, 3),
        "synth_s": round(synth_s, 3),
        "audio_duration_s": round(duration_s, 3),
        "realtime_factor": round(rtf, 3) if rtf is not None else None,
        "out_wav": str(out),
        "pass_tts": synth_s < 3.0,
    }


def bench_whisper(wav_path: Path, model_size: str = "tiny") -> dict:
    from faster_whisper import WhisperModel

    t0 = time.perf_counter()
    model = WhisperModel(
        model_size,
        device="cpu",
        compute_type="int8",
        download_root=str(DATA / "whisper"),
    )
    load_s = time.perf_counter() - t0

    t1 = time.perf_counter()
    segments, info = model.transcribe(str(wav_path), beam_size=1, vad_filter=True)
    text = " ".join(s.text.strip() for s in segments).strip()
    stt_s = time.perf_counter() - t1

    return {
        "engine": "faster-whisper",
        "model": model_size,
        "wav": str(wav_path),
        "load_s": round(load_s, 3),
        "stt_s": round(stt_s, 3),
        "text": text,
        "language": getattr(info, "language", None),
        "pass_stt": stt_s < 2.0,
    }


def download_assets() -> None:
    """Fetch Kokoro ONNX + voices.bin used by theiler/kokoro-onnx docs."""
    from huggingface_hub import hf_hub_download

    _ensure_dirs()
    kokoro_dir = DATA / "kokoro"
    kokoro_dir.mkdir(parents=True, exist_ok=True)

    # Models commonly used with kokoro-onnx package
    files = [
        ("onnx-community/Kokoro-82M-ONNX", "onnx/model.onnx", "kokoro-v1.0.onnx"),
        ("onnx-community/Kokoro-82M-ONNX", "voices/af_heart.bin", "voices-v1.0.bin"),
    ]
    # Prefer theiler's documented assets if present on HF
    try:
        model = hf_hub_download(
            repo_id="hexgrad/Kokoro-82M",
            filename="kokoro-v0_19.onnx",
            local_dir=str(kokoro_dir),
        )
        print("note: found legacy onnx", model)
    except Exception as e:
        print("legacy download skipped:", e)

    # Primary: download via kokoro-onnx recommended URLs if HF layout differs
    import urllib.request

    urls = {
        "kokoro-v1.0.onnx": "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx",
        "voices-v1.0.bin": "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin",
    }
    for name, url in urls.items():
        dest = kokoro_dir / name
        if dest.exists() and dest.stat().st_size > 1_000_000:
            print("exists", dest)
            continue
        print("downloading", url)
        urllib.request.urlretrieve(url, dest)
        print("saved", dest, dest.stat().st_size)


def _configure_espeak() -> None:
    """Point phonemizer/kokoro at Homebrew espeak-ng when the wheel data path is broken."""
    import os

    brew_data = Path("/opt/homebrew/share/espeak-ng-data")
    brew_bin = Path("/opt/homebrew/bin/espeak-ng")
    if brew_data.is_dir():
        os.environ.setdefault("ESPEAK_DATA_PATH", str(brew_data))
    if brew_bin.is_file():
        os.environ.setdefault("PHONEMIZER_ESPEAK_PATH", str(brew_bin))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--text", default=SAMPLE_TEXT)
    parser.add_argument(
        "--wav",
        default=str(PILOT_OUT / "kokoro_pilot.wav"),
        help="WAV for STT bench (default: pilot TTS output from prior/this run)",
    )
    parser.add_argument("--whisper-model", default="tiny")
    args = parser.parse_args()
    _ensure_dirs()
    _configure_espeak()

    if args.download:
        download_assets()

    report: dict = {"ok": True, "tts": None, "stt": None}

    try:
        report["tts"] = bench_kokoro(args.text)
    except Exception as e:
        report["ok"] = False
        report["tts_error"] = f"{type(e).__name__}: {e}"

    # Prefer explicit --wav; else reuse TTS output written by bench_kokoro
    wav = Path(args.wav)
    if not wav.exists() and (PILOT_OUT / "kokoro_pilot.wav").exists():
        wav = PILOT_OUT / "kokoro_pilot.wav"
    if wav.exists():
        try:
            report["stt"] = bench_whisper(wav, args.whisper_model)
        except Exception as e:
            report["ok"] = False
            report["stt_error"] = f"{type(e).__name__}: {e}"
    else:
        report["stt_error"] = f"wav missing: {wav}"
        report["ok"] = False

    tts_pass = bool(report.get("tts") and report["tts"].get("pass_tts"))
    stt_pass = bool(report.get("stt") and report["stt"].get("pass_stt"))
    report["pilot_pass"] = tts_pass and stt_pass
    report["gate"] = {
        "tts_synth_lt_3s": tts_pass,
        "stt_lt_2s": stt_pass,
    }

    out_json = PILOT_OUT / "bench_report.json"
    out_json.write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    print(f"\nWrote {out_json}", file=sys.stderr)
    return 0 if report["pilot_pass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
