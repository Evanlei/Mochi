#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_build_dir=$(mktemp -d /private/tmp/mochi-m3-challenger.XXXXXX)
trap 'rm -rf "$test_build_dir"' EXIT

echo "Compiling M3 Challenger-1 Empirical Stress Harness..."
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$test_build_dir/module-cache" \
    Mochi/Mochi/SpotifyAuthorization.swift \
    Mochi/Mochi/SpotifyAuthTypes.swift \
    Mochi/Mochi/SpotifyCallbackListener.swift \
    Mochi/Mochi/SpotifyTokenClient.swift \
    Mochi/Mochi/SpotifyTokenStore.swift \
    Mochi/Mochi/SpotifyAuthModel.swift \
    Mochi/Mochi/SpotifyPlaybackClient.swift \
    Mochi/Mochi/SpotifyPlaybackModel.swift \
    Mochi/Mochi/LocalSpotifyClient.swift \
    Mochi/Mochi/SpotifySearchClient.swift \
    Mochi/Mochi/SpotifySearchModel.swift \
    Mochi/Mochi/MochiBackendClient.swift \
    Mochi/Mochi/MochiArtistPreferences.swift \
    Mochi/Mochi/MochiCompanionView.swift \
    Mochi/Mochi/MochiEngine.swift \
    Mochi/Mochi/MochiCompanionController.swift \
    Mochi/Mochi/NowPlayingView.swift \
    Mochi/Mochi/ContentView.swift \
    Tests/SpotifyTestSupport.swift \
    Tests/M3ChallengerChecks.swift \
    -o "$test_build_dir/m3-challenger-checks"

echo "Executing M3 Challenger-1 Empirical Stress Harness..."
"$test_build_dir/m3-challenger-checks" "$@"
