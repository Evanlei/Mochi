#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mochi_demo_build=$(mktemp -d /private/tmp/mochi-readme-demo.XXXXXX)
trap 'rm -rf "$mochi_demo_build"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$mochi_demo_build/module-cache" \
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
    Tests/SpotifyTestSupport.swift scripts/ReadmeDemo.swift -o "$mochi_demo_build/render-demo"
"$mochi_demo_build/render-demo" "${1:-design/demo}"
