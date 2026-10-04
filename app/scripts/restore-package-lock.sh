#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
lock_dir=AllDayIDreamAboutSports.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$lock_dir"
cp Package.resolved "$lock_dir/Package.resolved"
