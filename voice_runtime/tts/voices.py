"""Voice catalog: Kokoro presets + custom reference WAVs for Chatterbox."""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"
BUILTIN_REF_DIR = DATA / "references"
KOKORO_VOICES_BIN = DATA / "kokoro" / "voices-v1.0.bin"

# Friendly labels for common Kokoro ids (rest fall back to id).
_KOKORO_LABELS: dict[str, str] = {
    "af_heart": "Heart (US female)",
    "af_bella": "Bella (US female)",
    "af_nicole": "Nicole (US female)",
    "af_sarah": "Sarah (US female)",
    "af_sky": "Sky (US female)",
    "am_adam": "Adam (US male)",
    "am_michael": "Michael (US male)",
    "bf_emma": "Emma (UK female)",
    "bf_isabella": "Isabella (UK female)",
    "bm_george": "George (UK male)",
    "bm_lewis": "Lewis (UK male)",
}


def _safe_stem(name: str) -> str:
    stem = Path(name).stem.strip().lower()
    stem = re.sub(r"[^a-z0-9_\-]+", "_", stem)
    stem = re.sub(r"_+", "_", stem).strip("_")
    return stem or "voice"


def reference_dirs() -> list[Path]:
    """User library first, then bundled references."""
    dirs: list[Path] = []
    env = (os.environ.get("VOICE_REFERENCES_DIR") or "").strip()
    if env:
        dirs.append(Path(env).expanduser())
    # Flutter AppPaths default (desktop)
    home = os.environ.get("HOME") or os.environ.get("USERPROFILE") or ""
    if home:
        dirs.append(Path(home) / ".uncensored-ai" / "voice" / "references")
    dirs.append(BUILTIN_REF_DIR)
    # Dedupe while preserving order
    seen: set[str] = set()
    out: list[Path] = []
    for d in dirs:
        key = str(d.resolve()) if d.exists() else str(d)
        if key in seen:
            continue
        seen.add(key)
        out.append(d)
    return out


def primary_reference_dir() -> Path:
    """Writable dir for imported WAVs."""
    for d in reference_dirs():
        try:
            d.mkdir(parents=True, exist_ok=True)
            return d
        except OSError:
            continue
    BUILTIN_REF_DIR.mkdir(parents=True, exist_ok=True)
    return BUILTIN_REF_DIR


def list_kokoro_voice_ids() -> list[str]:
    if not KOKORO_VOICES_BIN.is_file():
        return sorted(_KOKORO_LABELS.keys())
    try:
        import numpy as np

        with np.load(str(KOKORO_VOICES_BIN)) as z:
            return sorted(str(k) for k in z.files)
    except Exception:  # noqa: BLE001
        return sorted(_KOKORO_LABELS.keys())


def list_reference_voices() -> list[dict[str, Any]]:
    found: dict[str, Path] = {}
    for d in reference_dirs():
        if not d.is_dir():
            continue
        for wav in sorted(d.glob("*.wav")):
            if wav.stat().st_size < 1000:
                continue
            vid = f"ref:{_safe_stem(wav.name)}"
            # Prefer first occurrence (user library over bundled)
            found.setdefault(vid, wav)
    return [
        {
            "id": vid,
            "label": path.stem.replace("_", " ").title(),
            "kind": "reference",
            "path": str(path.resolve()),
            "backend": "chatterbox",
        }
        for vid, path in sorted(found.items(), key=lambda kv: kv[1].name.lower())
    ]


def list_kokoro_voices() -> list[dict[str, Any]]:
    return [
        {
            "id": f"kokoro:{vid}",
            "label": _KOKORO_LABELS.get(vid, vid.replace("_", " ")),
            "kind": "kokoro",
            "preset": vid,
            "backend": "kokoro",
        }
        for vid in list_kokoro_voice_ids()
    ]


def catalog(*, active_backend: str | None = None) -> dict[str, Any]:
    backend = (active_backend or os.environ.get("VOICE_TTS_BACKEND") or "").lower()
    kokoro = list_kokoro_voices()
    refs = list_reference_voices()
    if backend.startswith("chatterbox"):
        voices = refs + kokoro  # refs first for clone engines
        recommended = "reference"
    elif backend == "kokoro":
        voices = kokoro + refs
        recommended = "kokoro"
    else:
        voices = refs + kokoro
        recommended = "reference"

    default_id = (os.environ.get("VOICE_TTS_VOICE") or "").strip()
    if not default_id:
        preset = (os.environ.get("VOICE_PRESET") or "af_heart").strip()
        ref_env = (os.environ.get("VOICE_TTS_REFERENCE") or "").strip()
        if recommended == "reference" and refs:
            if ref_env:
                for v in refs:
                    if Path(v["path"]).resolve() == Path(ref_env).expanduser().resolve():
                        default_id = v["id"]
                        break
            if not default_id:
                default_id = refs[0]["id"]
        else:
            default_id = f"kokoro:{preset}"

    return {
        "voices": voices,
        "default_id": default_id,
        "reference_dirs": [str(d) for d in reference_dirs()],
        "import_dir": str(primary_reference_dir()),
        "active_backend": backend or None,
        "recommended_kind": recommended,
    }


def resolve_voice(voice_id: str | None) -> dict[str, Any]:
    """Map a catalog id (or bare kokoro preset / path) to speak kwargs."""
    raw = (voice_id or "").strip()
    if not raw:
        raw = (os.environ.get("VOICE_TTS_VOICE") or "").strip()
    if not raw:
        preset = (os.environ.get("VOICE_PRESET") or "af_heart").strip()
        ref = (os.environ.get("VOICE_TTS_REFERENCE") or "").strip()
        if ref and Path(ref).expanduser().is_file():
            return {
                "id": "ref:env",
                "kind": "reference",
                "voice": preset,
                "reference_wav": str(Path(ref).expanduser().resolve()),
            }
        return {
            "id": f"kokoro:{preset}",
            "kind": "kokoro",
            "voice": preset,
            "reference_wav": None,
        }

    if raw.startswith("kokoro:"):
        preset = raw.split(":", 1)[1] or "af_heart"
        return {
            "id": raw,
            "kind": "kokoro",
            "voice": preset,
            "reference_wav": None,
        }

    if raw.startswith("ref:"):
        stem = raw.split(":", 1)[1]
        for v in list_reference_voices():
            if v["id"] == raw or Path(v["path"]).stem.lower() == stem.lower():
                return {
                    "id": v["id"],
                    "kind": "reference",
                    "voice": stem,
                    "reference_wav": v["path"],
                }
        raise FileNotFoundError(f"reference voice not found: {raw}")

    # Bare path
    path = Path(raw).expanduser()
    if path.is_file() and path.suffix.lower() == ".wav":
        return {
            "id": f"ref:{_safe_stem(path.name)}",
            "kind": "reference",
            "voice": path.stem,
            "reference_wav": str(path.resolve()),
        }

    # Bare kokoro preset name
    return {
        "id": f"kokoro:{raw}",
        "kind": "kokoro",
        "voice": raw,
        "reference_wav": None,
    }


def import_reference_wav(filename: str, data: bytes) -> dict[str, Any]:
    if len(data) < 1000:
        raise ValueError("WAV too small — use a clear >5s sample for cloning")
    stem = _safe_stem(filename)
    dest_dir = primary_reference_dir()
    dest = dest_dir / f"{stem}.wav"
    # Avoid clobber: add suffix
    n = 1
    while dest.exists():
        dest = dest_dir / f"{stem}_{n}.wav"
        n += 1
    dest.write_bytes(data)
    vid = f"ref:{_safe_stem(dest.name)}"
    return {
        "id": vid,
        "label": dest.stem.replace("_", " ").title(),
        "kind": "reference",
        "path": str(dest.resolve()),
        "backend": "chatterbox",
    }


def delete_reference_voice(voice_id: str) -> dict[str, Any]:
    """Delete a custom clone WAV. Kokoro presets cannot be removed."""
    vid = (voice_id or "").strip()
    if not vid.startswith("ref:"):
        raise ValueError("only custom clone voices (ref:…) can be deleted")

    match: dict[str, Any] | None = None
    for v in list_reference_voices():
        if v["id"] == vid:
            match = v
            break
    if match is None:
        raise FileNotFoundError(f"voice not found: {vid}")

    path = Path(match["path"]).resolve()
    allowed_roots = []
    for d in reference_dirs():
        try:
            allowed_roots.append(d.resolve())
        except OSError:
            continue
    if not any(
        path == root or root in path.parents for root in allowed_roots
    ):
        raise PermissionError(f"refusing to delete outside voice libraries: {path}")

    if not path.is_file():
        raise FileNotFoundError(f"file missing: {path}")
    path.unlink()
    return {"id": vid, "path": str(path), "deleted": True}
