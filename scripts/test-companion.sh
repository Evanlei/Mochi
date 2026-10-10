#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build_dir=$(mktemp -d /private/tmp/mochi-companion-tests.XXXXXX)
trap 'rm -rf "$test_build_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$test_build_dir/module-cache" \
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
    Tests/CompanionChecks.swift -o "$test_build_dir/companion-checks"
if [[ -n "${MOCHI_CHECK_APP_INFO:-}" ]]; then
    # Exercise the built app's transport policy in a signed sandboxed test bundle.
    test_app="$test_build_dir/CompanionChecks.app"
    mkdir -p "$test_app/Contents/MacOS"
    cp "$MOCHI_CHECK_APP_INFO" "$test_app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable companion-checks" "$test_app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.evan.Mochi.companion-checks" "$test_app/Contents/Info.plist"
    cp "$test_build_dir/companion-checks" "$test_app/Contents/MacOS/companion-checks"
    cat > "$test_build_dir/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>
</dict></plist>
PLIST
    codesign --force --sign - --entitlements "$test_build_dir/entitlements.plist" "$test_app"
    "$test_app/Contents/MacOS/companion-checks" "$@"
else
    "$test_build_dir/companion-checks" "$@"
fi
