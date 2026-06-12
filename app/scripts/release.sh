#!/usr/bin/env bash
# End-to-end local release: build → sign → DMG → notarize → staple → appcast → R2.
# Adapted from the AI Thing release flow (DMG + keychain notary profile +
# generate_appcast), with R2 upload instead of scp.
#
#   ./scripts/release.sh 1.0.0 [build_number]
#
# One-time prereqs (see app/README.md):
#   - Developer ID Application cert in your login keychain (team 983LBM5U6B)
#   - xcrun notarytool store-credentials notary-profile --apple-id <id> \
#       --team-id 983LBM5U6B --password <app-specific-password>
#   - Sparkle EdDSA private key in your keychain (created by generate_keys)
#   - aws CLI + R2 env vars: R2_ENDPOINT, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version> [build]}"
BUILD="${2:-$(date +%y%m%d%H%M)}"
APP_NAME="All Day I Dream About Sports"
DMG_NAME="AllDayIDreamAboutSports-${VERSION}.dmg"
TEAM_ID="983LBM5U6B"
SIGN_ID="Developer ID Application: Nishant Hada (${TEAM_ID})"
# All released DMGs live here so generate_appcast can compute deltas.
RELEASES_DIR="${RELEASES_DIR:-$HOME/Releases/AllDayIDreamAboutSports}"
SPARKLE_BIN="build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"

echo "── 1/7 Generate project + archive (v${VERSION}, build ${BUILD})"
xcodegen
xcodebuild archive \
  -project AllDayIDreamAboutSports.xcodeproj \
  -scheme AllDayIDreamAboutSports \
  -configuration Release \
  -archivePath build/App.xcarchive \
  -derivedDataPath build/DerivedData \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="Developer ID Application" | tail -3

echo "── 2/7 Export"
xcodebuild -exportArchive \
  -archivePath build/App.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist | tail -3
APP="build/export/${APP_NAME}.app"

echo "── 3/7 Verify code signature"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|Identifier' | head -5

echo "── 4/7 Notarize the app, staple"
ditto -c -k --keepParent "$APP" build/notarize-app.zip
xcrun notarytool submit build/notarize-app.zip --keychain-profile notary-profile --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP" # expect: Notarized Developer ID

echo "── 5/7 Build, sign, notarize, staple the DMG"
rm -rf build/dmg && mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "$APP_NAME" -srcfolder build/dmg \
  -format UDZO -imagekey zlib-level=9 -fs HFS+ -ov "build/${DMG_NAME}"
codesign --sign "$SIGN_ID" --timestamp "build/${DMG_NAME}"
xcrun notarytool submit "build/${DMG_NAME}" --keychain-profile notary-profile --wait
xcrun stapler staple "build/${DMG_NAME}"
codesign -dv --verbose=4 "build/${DMG_NAME}" 2>&1 | grep -E 'Authority|TeamIdentifier' | head -3

echo "── 6/7 Appcast (EdDSA key comes from your keychain)"
mkdir -p "$RELEASES_DIR"
cp "build/${DMG_NAME}" "$RELEASES_DIR/"
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://download.alldayidreamaboutsports.com/" \
  "$RELEASES_DIR"

echo "── 7/7 Upload to R2 (download.alldayidreamaboutsports.com)"
if [[ -n "${R2_ENDPOINT:-}" ]]; then
  aws s3 sync "$RELEASES_DIR" "s3://alldayidreamaboutsports-downloads/" \
    --endpoint-url "$R2_ENDPOINT" --checksum-algorithm CRC32 \
    --exclude "*" --include "*.dmg" --include "appcast.xml" --include "*.delta"
  echo "✅ Live: https://download.alldayidreamaboutsports.com/${DMG_NAME}"
else
  echo "⚠️ R2_ENDPOINT not set — upload skipped. Files ready in $RELEASES_DIR"
fi
