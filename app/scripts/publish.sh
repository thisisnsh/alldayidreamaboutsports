#!/usr/bin/env bash
# Publish a CI-built DMG: appcast + Sparkle deltas + R2 upload — all local.
#
#   ./scripts/publish.sh <path-to-dmg> [version]
#
# CI (app-release.yml) only produces the code-signed, notarized, stapled DMG and
# uploads it as a workflow artifact. Download that DMG, test it, then run this to
# cut the actual release. (For a full from-scratch local build instead, use
# release.sh.)
#
# One-time prereqs:
#   - Sparkle EdDSA private key in your keychain (created by generate_keys);
#     generate_appcast reads it automatically.
#   - aws CLI + R2 env vars: R2_ENDPOINT, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
set -euo pipefail

DMG_PATH="${1:?usage: publish.sh <path-to-dmg> [version]}"
[[ -f "$DMG_PATH" ]] || { echo "✗ DMG not found: $DMG_PATH" >&2; exit 1; }

# CHANNEL=release (default) publishes to production; CHANNEL=staging targets the
# staging download bucket + feed so test builds never reach real users.
CHANNEL="${CHANNEL:-release}"
case "$CHANNEL" in
  release) DOWNLOAD_HOST="https://download.alldayidreamaboutsports.com"
           R2_BUCKET="alldayidreamaboutsports-downloads" ;;
  staging) DOWNLOAD_HOST="https://download-staging.alldayidreamaboutsports.com"
           R2_BUCKET="alldayidreamaboutsports-staging-downloads" ;;
  *) echo "✗ CHANNEL must be 'release' or 'staging' (got '$CHANNEL')" >&2; exit 1 ;;
esac
echo "── channel=${CHANNEL} host=${DOWNLOAD_HOST}"
SPARKLE_VERSION="2.6.4"
# All released DMGs live here so generate_appcast can compute deltas across
# versions. Persisted between releases; on a fresh machine we backfill from R2.
# Per-channel dir so staging and release deltas/appcasts never cross-contaminate.
RELEASES_DIR="${RELEASES_DIR:-$HOME/Releases/AllDayIDreamAboutSports/${CHANNEL}}"
SPARKLE_HOME="${SPARKLE_HOME:-$HOME/.cache/sparkle-${SPARKLE_VERSION}}"

echo "── 1/4 Ensure generate_appcast (Sparkle ${SPARKLE_VERSION})"
GEN="$SPARKLE_HOME/bin/generate_appcast"
if [[ ! -x "$GEN" ]]; then
  mkdir -p "$SPARKLE_HOME"
  curl -fsSL -o "$SPARKLE_HOME/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
  tar -xf "$SPARKLE_HOME/sparkle.tar.xz" -C "$SPARKLE_HOME"
fi

echo "── 2/4 Stage DMG + backfill prior versions for deltas"
mkdir -p "$RELEASES_DIR"
cp -f "$DMG_PATH" "$RELEASES_DIR/"
# Best-effort: pull any prior DMGs we don't already have from the live appcast,
# so generate_appcast can build deltas for users on older versions.
if curl -fsSL "${DOWNLOAD_HOST}/appcast.xml" -o "$RELEASES_DIR/.appcast-prev.xml" 2>/dev/null; then
  grep -oE 'url="[^"]+\.dmg"' "$RELEASES_DIR/.appcast-prev.xml" \
    | sed -E 's/^url="(.*)"$/\1/' | sort -u | while read -r url; do
      fn="$(basename "$url")"
      [[ -f "$RELEASES_DIR/$fn" ]] || curl -fsSL "$url" -o "$RELEASES_DIR/$fn" || true
    done
  rm -f "$RELEASES_DIR/.appcast-prev.xml"
fi

echo "── 3/4 Generate appcast + deltas (EdDSA key from keychain)"
"$GEN" --download-url-prefix "${DOWNLOAD_HOST}/" "$RELEASES_DIR"

echo "── 4/4 Upload to R2 (${DOWNLOAD_HOST})"
if [[ -n "${R2_ENDPOINT:-}" ]]; then
  aws s3 sync "$RELEASES_DIR" "s3://${R2_BUCKET}/" \
    --endpoint-url "$R2_ENDPOINT" --checksum-algorithm CRC32 \
    --exclude "*" --include "*.dmg" --include "appcast.xml" --include "*.delta"
  echo "✅ Live: ${DOWNLOAD_HOST}/$(basename "$DMG_PATH")"
  echo "   Ensure ${DOWNLOAD_HOST}/latest redirects to this DMG."
else
  echo "⚠️ R2_ENDPOINT not set — upload skipped. Files ready in $RELEASES_DIR"
fi
