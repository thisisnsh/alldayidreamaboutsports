#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library Sources/Overlay/NotchDropMotion.swift \
  Tests/NotchDropMotionTests.swift -o "$test_dir/notch-motion-tests"
"$test_dir/notch-motion-tests"
