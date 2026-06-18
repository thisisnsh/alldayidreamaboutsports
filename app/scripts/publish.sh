#!/usr/bin/env bash
# Publish a CI-built DMG: appcast + Sparkle deltas + R2 upload, all local.
#
#   ./scripts/publish.sh <path-to-dmg> [--notes release-notes.html] [--channel staging|release]
#
# CI (app-release.yml) only produces the code-signed, notarized, stapled DMG and
# uploads it as a workflow artifact. Download that DMG, test it, then run this to
# publish the Sparkle feed.
#
# One-time prereqs:
#   - Sparkle EdDSA private key in your keychain (created by generate_keys);
#     generate_appcast reads it automatically.
#   - aws CLI, used only as an S3-compatible client for R2 uploads.
#   - R2 env vars: R2_ENDPOINT, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY
set -euo pipefail

usage() {
  echo "usage: publish.sh <path-to-dmg> [--notes release-notes.html] [--channel staging|release]" >&2
}

DMG_PATH=""
CHANGE_NOTES_HTML="${CHANGE_NOTES_HTML:-}"
LEGACY_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes|--change-notes|--release-notes-html)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      CHANGE_NOTES_HTML="$2"
      shift 2
      ;;
    --channel)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      CHANNEL="$2"
      shift 2
      ;;
    --staging)
      CHANNEL="staging"
      shift
      ;;
    --release)
      CHANNEL="release"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$DMG_PATH" ]]; then
        DMG_PATH="$1"
      elif [[ -z "$CHANGE_NOTES_HTML" && -f "$1" ]]; then
        CHANGE_NOTES_HTML="$1"
      elif [[ -z "$LEGACY_VERSION" ]]; then
        LEGACY_VERSION="$1"
      else
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

[[ -n "$DMG_PATH" ]] || { usage; exit 1; }
[[ -f "$DMG_PATH" ]] || { echo "✗ DMG not found: $DMG_PATH" >&2; exit 1; }
if [[ -n "$CHANGE_NOTES_HTML" && ! -f "$CHANGE_NOTES_HTML" ]]; then
  echo "✗ change notes HTML not found: $CHANGE_NOTES_HTML" >&2
  exit 1
fi
if [[ -n "$LEGACY_VERSION" ]]; then
  echo "⚠️ Ignoring legacy version argument '$LEGACY_VERSION'; the appcast reads the version from the DMG."
fi

# CHANNEL=staging (default) targets the staging download bucket + feed so test
# builds never reach real users. Use --release or CHANNEL=release for production.
CHANNEL="${CHANNEL:-staging}"
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
if [[ -n "$CHANGE_NOTES_HTML" ]]; then
  NOTES_DEST="$RELEASES_DIR/$(basename "${DMG_PATH%.*}").html"
  cp -f "$CHANGE_NOTES_HTML" "$NOTES_DEST"
  echo "   staged change notes: $NOTES_DEST"
fi
# Best-effort: pull any prior DMGs and HTML notes we don't already have from the
# live appcast, so generate_appcast can build deltas and preserve notes links.
if curl -fsSL "${DOWNLOAD_HOST}/appcast.xml" -o "$RELEASES_DIR/.appcast-prev.xml" 2>/dev/null; then
  { grep -oE 'url="[^"]+\.dmg"' "$RELEASES_DIR/.appcast-prev.xml" \
    | sed -E 's/^url="(.*)"$/\1/' || true; } | sort -u | while read -r url; do
      fn="$(basename "$url")"
      [[ -f "$RELEASES_DIR/$fn" ]] || curl -fsSL "$url" -o "$RELEASES_DIR/$fn" || true
    done
  { grep -oE "https?://[^<\"]+\.html" "$RELEASES_DIR/.appcast-prev.xml" || true; } \
    | sort -u | while read -r url; do
      fn="$(basename "$url")"
      [[ -f "$RELEASES_DIR/$fn" ]] || curl -fsSL "$url" -o "$RELEASES_DIR/$fn" || true
    done
  rm -f "$RELEASES_DIR/.appcast-prev.xml"
fi

echo "── 3/4 Generate appcast + deltas (EdDSA key from keychain)"
"$GEN" --download-url-prefix "${DOWNLOAD_HOST}/" "$RELEASES_DIR"

echo "── 4/4 Upload to R2 (${DOWNLOAD_HOST})"
if [[ -n "${R2_ENDPOINT:-}" ]]; then
  export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required for R2 upload}"
  export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required for R2 upload}"
  aws s3 sync "$RELEASES_DIR" "s3://${R2_BUCKET}/" \
    --endpoint-url "$R2_ENDPOINT" --checksum-algorithm CRC32 \
    --exclude "*" --include "*.dmg" --include "appcast.xml" --include "*.delta" --include "*.html"
  echo "✅ Live: ${DOWNLOAD_HOST}/$(basename "$DMG_PATH")"
  echo "   Ensure ${DOWNLOAD_HOST}/latest redirects to this DMG."
else
  echo "⚠️ R2_ENDPOINT not set — upload skipped. Files ready in $RELEASES_DIR"
fi
