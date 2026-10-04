#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library Sources/Services/RemoteData.swift Sources/Models/League.swift \
  Sources/Models/Team.swift Tests/RemoteDataTests.swift -o "$test_dir/remote-data-tests"
"$test_dir/remote-data-tests"
