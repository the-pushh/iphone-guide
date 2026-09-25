"""Local configuration. Provider credentials never cross into the iOS app."""

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import dotenv_values

ROOT = Path(__file__).resolve().parent


@dataclass(frozen=True)
class Settings:
    openrouter_key: str
    cartesia_key: str
    model: str
    voice: str
    tts_model: str
    stt_model: str
    greeting: str
    system_prompt: str
    reasoning_effort: str = "low"

    @classmethod
    def load(cls):
        values = {**dotenv_values(ROOT / ".env"), **os.environ}
        missing = [
            name
            for name in ("OPENROUTER_API_KEY", "CARTESIA_API_KEY")
            if not values.get(name, "").strip()
        ]
        if missing:
            raise ValueError("Add " + ", ".join(missing) + " to server/.env before connecting.")
        effort = values.get("OPENROUTER_REASONING_EFFORT", "low")
        if effort not in {"low", "high", "max"}:
            raise ValueError("OPENROUTER_REASONING_EFFORT must be low, high, or max.")
        return cls(
            openrouter_key=values["OPENROUTER_API_KEY"],
            cartesia_key=values["CARTESIA_API_KEY"],
            reasoning_effort=effort,
            model=values.get("OPENROUTER_MODEL", "z-ai/glm-5.3-flash"),
            voice=values.get("CARTESIA_VOICE_ID", "86e30c1d-714b-4074-a1f2-1cb6b552fb49"),
            tts_model=values.get("CARTESIA_TTS_MODEL", "sonic-3"),
            stt_model=values.get("CARTESIA_STT_MODEL", "ink-whisper"),
            greeting=values.get("GREETING", "Hi. What’s on your mind?"),
            system_prompt=(ROOT / "system_prompt.md").read_text().strip(),
        )
