#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -x backend/.venv/bin/python ]]; then
    echo "Run bash scripts/setup.sh first."
    exit 1
fi
mochi_status() {
    curl --fail --silent --max-time 2 http://127.0.0.1:8000/status |
        backend/.venv/bin/python -c 'import json,sys; value=json.load(sys.stdin); sys.exit(not(value.get("service")=="mochi" and value.get("api_version")==1))' 2>/dev/null
}
if ! mochi_status; then
    if backend/.venv/bin/python -c 'import socket,sys; probe=socket.socket(); probe.settimeout(1); sys.exit(probe.connect_ex(("127.0.0.1",8000))!=0)'; then
        echo "Port 8000 belongs to another service. Stop that service or use Mochi's Setup & Settings to check the connection."
        exit 1
    fi
    backend/.venv/bin/python backend/serve.py &
    mochi_engine_pid=$!
    trap 'kill "$mochi_engine_pid" 2>/dev/null || true' EXIT INT TERM
    mochi_ready=false
    for ((mochi_attempt=0; mochi_attempt<40; mochi_attempt++)); do
        if mochi_status; then mochi_ready=true; break; fi
        if ! kill -0 "$mochi_engine_pid" 2>/dev/null; then break; fi
        sleep 0.25
    done
    if [[ "$mochi_ready" != true ]]; then echo "The music engine couldn't start. Check the error above and retry."; exit 1; fi
fi
echo "Music engine ready. Run Mochi from Xcode (Command-R); keep this terminal open."
if [[ -n "${mochi_engine_pid:-}" ]]; then wait "$mochi_engine_pid"; fi
