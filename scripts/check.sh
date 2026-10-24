#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/test-backend.sh
for mochi_check in auth playback local-playback search discovery session engine; do
    bash "scripts/test-$mochi_check.sh"
done
if [[ "${1:-}" == "--ui" ]]; then
    bash scripts/test-companion.sh /private/tmp/mochi-release-preview
    bash scripts/test-up-next.sh /private/tmp/mochi-release-preview
    bash scripts/test-settings.sh /private/tmp/mochi-release-preview
fi
xcodebuild -quiet -project Mochi/Mochi.xcodeproj -scheme Mochi -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath build/checks CODE_SIGNING_ALLOWED=NO build
