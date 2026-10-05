#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build_dir=$(mktemp -d /private/tmp/mochi-playback-tests.XXXXXX)
trap 'rm -rf "$test_build_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 \
    Mochi/Mochi/SpotifyConfiguration.swift \
    Mochi/Mochi/SpotifyPKCE.swift \
    Mochi/Mochi/SpotifyAuthorization.swift \
    Mochi/Mochi/SpotifyLoginAttempt.swift \
    Mochi/Mochi/SpotifyAuthError.swift \
    Mochi/Mochi/SpotifyCallback.swift \
    Mochi/Mochi/SpotifyCallbackListener.swift \
    Mochi/Mochi/SpotifyTokens.swift \
    Mochi/Mochi/SpotifyTokenClient.swift \
    Mochi/Mochi/SpotifyTokenStore.swift \
    Mochi/Mochi/SpotifyAuthModel.swift \
    Mochi/Mochi/SpotifyPlaybackState.swift \
    Mochi/Mochi/SpotifyPlaybackClient.swift \
    Mochi/Mochi/SpotifyPlaybackModel.swift \
    Tests/PlaybackChecks.swift -o "$test_build_dir/playback-checks"
"$test_build_dir/playback-checks"
