#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
backend/.venv/bin/python Tests/BackendChecks.py
backend/.venv/bin/python Tests/SelectionChecks.py
if [[ "${1:-}" == "--python-only" ]]; then
    exit 0
fi
if [[ "${1:-}" == "--semantic" ]]; then
    backend/.venv/bin/python Tests/SelectionChecks.py --semantic
    backend/.venv/bin/python scripts/evaluate-intent.py --split test --semantic --check
fi
test_build_dir=$(mktemp -d /private/tmp/mochi-backend-tests.XXXXXX)
trap 'rm -rf "$test_build_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 \
    Mochi/Mochi/SpotifyAuthorization.swift \
    Mochi/Mochi/SpotifyAuthTypes.swift \
    Mochi/Mochi/SpotifyCallbackListener.swift \
    Mochi/Mochi/SpotifyTokenClient.swift \
    Mochi/Mochi/SpotifyTokenStore.swift \
    Mochi/Mochi/SpotifyAuthModel.swift \
    Mochi/Mochi/SpotifyPlaybackClient.swift \
    Mochi/Mochi/SpotifyPlaybackModel.swift \
    Mochi/Mochi/SpotifySearchClient.swift \
    Mochi/Mochi/SpotifySearchModel.swift \
    Mochi/Mochi/MochiBackendClient.swift \
    Mochi/Mochi/MochiCompanionView.swift \
    Mochi/Mochi/MochiCompanionController.swift \
    Mochi/Mochi/NowPlayingView.swift \
    Mochi/Mochi/ContentView.swift \
    Tests/SpotifyTestSupport.swift \
    Tests/BackendChecks.swift -o "$test_build_dir/backend-checks"
"$test_build_dir/backend-checks" "$@"
