"""Local configuration; API keys are never returned by the HTTP API."""

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

BACKEND_DIRECTORY = Path(__file__).resolve().parent


@dataclass(frozen=True)
class Settings:
    lastfm_key: str = ""
    mode: str = "live"
    reccobeats_enabled: bool = False
    data_directory: Path = BACKEND_DIRECTORY / ".data"

    @classmethod
    def from_environment(cls):
        load_dotenv(BACKEND_DIRECTORY / ".env", override=False)
        mode = os.environ.get("MOCHI_CATALOG_MODE", "live")
        if mode not in {"live", "sample"}:
            raise ValueError("MOCHI_CATALOG_MODE must be live or sample")
        return cls(lastfm_key=os.environ.get("LASTFM_API_KEY", "").strip(), mode=mode,
                   reccobeats_enabled=os.environ.get("MOCHI_RECCOBEATS_ENABLED", "false").lower() == "true",
                   data_directory=Path(os.environ.get("MOCHI_DATA_DIRECTORY", BACKEND_DIRECTORY / ".data")))
