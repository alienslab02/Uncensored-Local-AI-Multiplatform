#!/usr/bin/env python3
"""Compare Kokoro vs Chatterbox Nano latency / expressive tags."""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
OUT = ROOT / "pilot" / "out"
OUT.mkdir(parents=True, exist_ok=True)

SAMPLES = [
    "Hello, how are you today?",
    "Hmm, let me think about that for a second.",
    "Sure [chuckle], that works for me.",
]


def _bench_cls(name: str, factory) -> dict:
    t0 = time.perf_counter()
    try:
        backend = factory()
        backend.load()
    except Exception as e:  # noqa: BLE001
        return {
            "backend": name,
            "ok": False,
            "error": f"{type(e).__name__}: {e}",
            "pass_chat": False,
        }
    load_s = time.perf_counter() - t0

    rows = []
    for text in SAMPLES:
        t1 = time.perf_counter()
        try:
            result = backend.speak(text)
            dt = time.perf_counter() - t1
            rows.append(
                {
                    "text": text,
                    "ok": True,
                    "seconds": round(dt, 3),
                    "bytes": len(result.wav_bytes),
                    "sr": result.sample_rate,
                }
            )
            safe = "".join(c if c.isalnum() else "_" for c in text)[:40]
            (OUT / f"{name}_{safe}.wav").write_bytes(result.wav_bytes)
        except Exception as e:  # noqa: BLE001
            rows.append(
                {
                    "text": text,
                    "ok": False,
                    "error": f"{type(e).__name__}: {e}",
                }
            )

    times = [r["seconds"] for r in rows if r.get("ok")]
    # First synth is often cold (graph compile); gate on warm utterances
    warm = times[1:] if len(times) > 1 else times
    return {
        "backend": name,
        "ok": True,
        "load_seconds": round(load_s, 3),
        "samples": rows,
        "warm_avg_s": round(sum(warm) / len(warm), 3) if warm else None,
        "pass_chat": bool(warm) and max(warm) < 8.0,
    }


def main() -> int:
    from tts.chatterbox_backend import ChatterboxNanoBackend
    from tts.kokoro_backend import KokoroBackend

    report = {"backends": {}}
    for name, factory in (
        ("kokoro", KokoroBackend),
        ("chatterbox_nano", ChatterboxNanoBackend),
    ):
        print(f"=== {name} ===", flush=True)
        report["backends"][name] = _bench_cls(name, factory)
        print(json.dumps(report["backends"][name], indent=2), flush=True)

    out = OUT / "tts_backends_report.json"
    out.write_text(json.dumps(report, indent=2))
    print(f"Wrote {out}", flush=True)

    nano = report["backends"].get("chatterbox_nano", {})
    kokoro = report["backends"].get("kokoro", {})
    if nano.get("pass_chat"):
        print("RECOMMEND_DEFAULT=chatterbox_nano")
        return 0
    if kokoro.get("pass_chat"):
        print("RECOMMEND_DEFAULT=kokoro")
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
