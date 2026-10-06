#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build_dir=$(mktemp -d /private/tmp/mochi-companion-tests.XXXXXX)
trap 'rm -rf "$test_build_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 \
    Mochi/Mochi/MochiCompanionView.swift \
    Mochi/Mochi/MochiCompanionController.swift \
    Tests/CompanionChecks.swift -o "$test_build_dir/companion-checks"
"$test_build_dir/companion-checks" "$@"
