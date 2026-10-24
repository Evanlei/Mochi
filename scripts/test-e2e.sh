#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

test_build_dir=$(mktemp -d /private/tmp/mochi-e2e-tests.XXXXXX)
trap 'rm -rf "$test_build_dir"' EXIT

echo "Compiling Mochi E2E test suite..."
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
    Tests/E2E/E2ESupport.swift \
    Tests/E2E/Tier1FeatureCoverageTests.swift \
    Tests/E2E/Tier2BoundaryCornerTests.swift \
    Tests/E2E/Tier3CombinationTests.swift \
    Tests/E2E/Tier4RealWorldScenariosTests.swift \
    Tests/E2E/MochiE2ETests.swift \
    -o "$test_build_dir/mochi-e2e-tests"

echo "Compilation successful. Executing E2E tests..."
"$test_build_dir/mochi-e2e-tests" "$@"
