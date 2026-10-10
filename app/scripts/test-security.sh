#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library Sources/Services/RemoteData.swift Sources/Models/League.swift \
  Sources/Models/Team.swift Tests/RemoteDataTests.swift -o "$test_dir/remote-data-tests"
"$test_dir/remote-data-tests"
swiftc -parse-as-library Sources/Models/MatchModels.swift Sources/Services/MatchDiff.swift \
  Tests/MatchSecurityTests.swift -o "$test_dir/match-security-tests"
"$test_dir/match-security-tests"
swiftc -parse-as-library Sources/Models/DataStatus.swift Tests/DataStatusTests.swift \
  -o "$test_dir/data-status-tests"
"$test_dir/data-status-tests"
