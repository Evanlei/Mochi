#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build_dir=$(mktemp -d /private/tmp/mochi-auth-tests.XXXXXX)
trap 'rm -rf "$test_build_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 \
    Mochi/Mochi/SpotifyAuthorization.swift \
    Mochi/Mochi/SpotifyAuthTypes.swift \
    Mochi/Mochi/SpotifyCallbackListener.swift \
    Mochi/Mochi/SpotifyTokenClient.swift \
    Mochi/Mochi/SpotifyTokenStore.swift \
    Mochi/Mochi/SpotifyAuthModel.swift \
    Tests/AuthChecks.swift -o "$test_build_dir/auth-checks"
"$test_build_dir/auth-checks" "$@"
