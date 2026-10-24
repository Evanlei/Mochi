#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../backend"
if ! command -v uv >/dev/null 2>&1; then
    echo "Install uv from https://docs.astral.sh/uv/getting-started/installation/ and rerun this script."
    exit 1
fi
uv sync --frozen --extra semantic --group build
uv run --frozen --extra semantic python ../scripts/prepare-intent-model.py
if [[ ! -f .env ]]; then
    cp .env.example .env
    chmod 600 .env
    echo "Add your Last.fm API key to backend/.env for development. Bundled builds use Setup & Settings."
fi
