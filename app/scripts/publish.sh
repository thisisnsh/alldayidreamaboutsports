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
#   - Sparkle generate_appcast at $SPARKLE_HOME/bin/generate_appcast.
#   - Node 22+; uploader deps are installed under app/scripts on first use.
#   - R2 env file: app/scripts/.publish.env (or R2_ENV_FILE=/path/to/env).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
# All released DMGs live here so generate_appcast can compute deltas across
# versions. Persisted between releases; on a fresh machine we backfill from R2.
# Per-channel dir so staging and release deltas/appcasts never cross-contaminate.
RELEASES_DIR="${RELEASES_DIR:-$HOME/Releases/AllDayIDreamAboutSports/${CHANNEL}}"
SPARKLE_HOME="${SPARKLE_HOME:-/Users/thisisnsh/projects/Sparkle}"

echo "── 1/4 Check generate_appcast"
GEN="$SPARKLE_HOME/bin/generate_appcast"
if [[ ! -x "$GEN" ]]; then
  echo "✗ generate_appcast not found or not executable: $GEN" >&2
  echo "  Set SPARKLE_HOME to a local Sparkle checkout/release directory." >&2
  exit 1
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
R2_ENV_FILE="${R2_ENV_FILE:-$SCRIPT_DIR/.publish.env}"
if [[ -n "${R2_ENDPOINT:-}" || -f "$R2_ENV_FILE" ]]; then
  if [[ ! -x "$SCRIPT_DIR/node_modules/.bin/tsx" || ! -d "$SCRIPT_DIR/node_modules/@aws-sdk/client-s3" ]]; then
    npm --prefix "$SCRIPT_DIR" install
  fi
  APPCAST_URL="${DOWNLOAD_HOST}/appcast.xml"
  if [[ -f "$R2_ENV_FILE" ]]; then
    "$SCRIPT_DIR/node_modules/.bin/tsx" --env-file="$R2_ENV_FILE" "$SCRIPT_DIR/upload-r2.ts" \
      "$RELEASES_DIR" "$R2_BUCKET"
    "$SCRIPT_DIR/node_modules/.bin/tsx" --env-file="$R2_ENV_FILE" "$SCRIPT_DIR/purge-cloudflare.ts" \
      "$APPCAST_URL"
  else
    "$SCRIPT_DIR/node_modules/.bin/tsx" "$SCRIPT_DIR/upload-r2.ts" "$RELEASES_DIR" "$R2_BUCKET"
    "$SCRIPT_DIR/node_modules/.bin/tsx" "$SCRIPT_DIR/purge-cloudflare.ts" "$APPCAST_URL"
  fi
  echo "✅ Live: ${DOWNLOAD_HOST}/$(basename "$DMG_PATH")"
  echo "   Ensure ${DOWNLOAD_HOST}/latest redirects to this DMG."
else
  echo "⚠️ R2 env not found — upload skipped. Files ready in $RELEASES_DIR"
  echo "   Create $R2_ENV_FILE or set R2_ENDPOINT/R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY."
fi
