#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build_dir=$(mktemp -d /private/tmp/mochi-engine-tests.XXXXXX)
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
    Tests/SpotifyTestSupport.swift Tests/EngineChecks.swift -o "$test_build_dir/engine-checks"
if [[ "${MOCHI_ENGINE_SANDBOX:-}" == "1" ]]; then
    test_app="$test_build_dir/EngineChecks.app"
    mkdir -p "$test_app/Contents/MacOS" "$test_app/Contents/Resources"
    cp "$test_build_dir/engine-checks" "$test_app/Contents/MacOS/engine-checks"
    ditto "build/beta/engine/mochi-backend" "$test_app/Contents/Resources/Engine"
    python3 - "$test_app/Contents/Info.plist" "$test_build_dir" <<'PLIST'
import plistlib,sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({"CFBundleExecutable":"engine-checks", "CFBundleIdentifier":"com.evan.Mochi.engine-checks", "CFBundlePackageType":"APPL"}))
root=Path(sys.argv[2])
(root/"parent.plist").write_bytes(plistlib.dumps({"com.apple.security.app-sandbox":True,"com.apple.security.network.client":True,"com.apple.security.network.server":True}))
(root/"child.plist").write_bytes(plistlib.dumps({"com.apple.security.app-sandbox":True,"com.apple.security.inherit":True}))
PLIST
    codesign --force --sign - --entitlements "$test_build_dir/child.plist" "$test_app/Contents/Resources/Engine/mochi-backend"
    codesign --force --sign - --entitlements "$test_build_dir/parent.plist" "$test_app"
    MOCHI_ENGINE_TEST_HELPER="$test_app/Contents/Resources/Engine/mochi-backend" "$test_app/Contents/MacOS/engine-checks"
else
    "$test_build_dir/engine-checks"
fi
