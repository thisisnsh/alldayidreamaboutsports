#!/usr/bin/env bash
# Re-encodes the promo reel for use as the site's fixed background layer, and
# extracts its first frame as the poster.
#
# The reel is NOT cut: all 64 seconds, same framing, at about a quarter of the
# weight. At background scale, behind a scrim and text, 2.5 Mbps and 10 Mbps
# are indistinguishable - so the re-encode costs nothing visually and saves
# every visitor about 67MB.
#
# Nothing here is committed. The three outputs go to the R2 bucket that already
# fronts the app downloads (download.alldayidreamaboutsports.com), which has a
# custom domain and cache rules already, so there is no new infrastructure.
#
#   ./scripts/encode-promo.sh [source.mp4] [outdir]
#
# Needs ffmpeg (brew install ffmpeg). macOS `avconvert` is the no-install
# fallback for the MP4 only; it cannot produce VP9.
set -euo pipefail

SRC="${1:-$HOME/Desktop/AllSportsPromo-Web.mp4}"
OUT="${2:-$(cd "$(dirname "$0")/.." && pwd)/.promo}"

[ -f "$SRC" ] || { echo "no source at $SRC" >&2; exit 1; }
mkdir -p "$OUT"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg not found." >&2
  echo "Fallback for the MP4 only:" >&2
  echo "  avconvert -p PresetHD1080p -s \"$SRC\" -o \"$OUT/promo.mp4\"" >&2
  echo "Install ffmpeg for the WebM and the poster: brew install ffmpeg" >&2
  exit 1
fi

echo "→ promo.mp4  (H.264, ~2.5 Mbps)"
ffmpeg -y -loglevel error -i "$SRC" \
  -an \
  -c:v libx264 -profile:v high -preset slow \
  -b:v 2500k -maxrate 3200k -bufsize 6000k \
  -vf "scale=-2:1080,fps=30" \
  -pix_fmt yuv420p -movflags +faststart \
  "$OUT/promo.mp4"

echo "→ promo.webm (VP9, ~1.8 Mbps)"
ffmpeg -y -loglevel error -i "$SRC" \
  -an \
  -c:v libvpx-vp9 -crf 36 -b:v 1800k -maxrate 2400k -bufsize 4800k \
  -row-mt 1 -deadline good -cpu-used 2 \
  -vf "scale=-2:1080,fps=30" \
  -pix_fmt yuv420p \
  "$OUT/promo.webm"

echo "→ promo-f1.webp (first frame - this is the LCP image, so it has to be small)"
# ffmpeg is only used to pull the frame; cwebp does the encode, because the
# Homebrew ffmpeg build does not ship libwebp.
ffmpeg -y -loglevel error -i "$SRC" -frames:v 1 -vf "scale=-2:1080" "$OUT/.f1.png"
cwebp -quiet -q 45 -m 6 -sharp_yuv -resize 1440 0 "$OUT/.f1.png" -o "$OUT/promo-f1.webp"
rm -f "$OUT/.f1.png"

ls -lh "$OUT"
cat <<'NOTE'

Upload the three files to the R2 bucket behind
download.alldayidreamaboutsports.com, at the bucket root:

  promo.mp4  promo.webm  promo-f1.webp

e.g. with wrangler:
  wrangler r2 object put <bucket>/promo.mp4     --file .promo/promo.mp4     --content-type video/mp4
  wrangler r2 object put <bucket>/promo.webm    --file .promo/promo.webm    --content-type video/webm
  wrangler r2 object put <bucket>/promo-f1.webp --file .promo/promo-f1.webp --content-type image/webp
NOTE
