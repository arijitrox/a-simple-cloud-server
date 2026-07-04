#!/usr/bin/env bash
# fetch-flickr.sh — pull a curated set of Arijit's own public Flickr photos
# (flickr.com/photos/arigraphy) for the personal website gallery.
#
# Photo IDs are scraped from each album page, then resolved through Flickr's
# keyless oEmbed API, which returns the exact available image URL (up to
# 1024px) plus the photo title. Results land in site-assets/flickr/<album>/
# as <id>.jpg + <id>.title.txt. Post-processing (resize/thumbs/manifest) is
# done by scripts/build-gallery.py.
#
# Usage: scripts/fetch-flickr.sh [per_album]   (default 8)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/homepage/site-assets/flickr"
UA="Mozilla/5.0 (X11; Linux x86_64; rv:127.0) Gecko/20100101 Firefox/127.0"
PER_ALBUM="${1:-8}"

# album-slug=album-id (verified against flickr.com/photos/arigraphy/albums)
ALBUMS=(
  "street=72157663142083069"
  "birds=72157661211488983"
  "landscapes=72157661233244950"
  "flowers=72157661503663791"
)

mkdir -p "$DEST"

for entry in "${ALBUMS[@]}"; do
  slug="${entry%%=*}"; album_id="${entry##*=}"
  outdir="$DEST/$slug"
  mkdir -p "$outdir"
  page_html="$(curl -sL -A "$UA" "https://www.flickr.com/photos/arigraphy/albums/$album_id/")"
  title="$(printf '%s' "$page_html" | grep -oE '<title>[^<]*' | head -1 | sed 's/<title>//')"
  echo "== $slug (album $album_id): $title"

  count=0
  while IFS= read -r photo_id; do
    [ "$count" -ge "$PER_ALBUM" ] && break
    out="$outdir/$photo_id.jpg"
    if [ -s "$out" ]; then count=$((count+1)); continue; fi

    meta="$(curl -sfL "https://www.flickr.com/services/oembed?url=https%3A%2F%2Fwww.flickr.com%2Fphotos%2Farigraphy%2F${photo_id}%2F&format=json&maxwidth=1600" || true)"
    img_url="$(printf '%s' "$meta" | python3 -c 'import sys,json
try:
    d = json.load(sys.stdin)
    print(d.get("url",""))
    sys.stderr.write(d.get("title",""))
except Exception:
    pass' 2>"$outdir/$photo_id.title.txt")"

    if [ -n "$img_url" ] && curl -sfL -A "$UA" "$img_url" -o "$out" && [ -s "$out" ]; then
      count=$((count+1))
      echo "   got $photo_id — $(cat "$outdir/$photo_id.title.txt")"
    else
      rm -f "$out" "$outdir/$photo_id.title.txt"
      echo "   skip $photo_id (no public size)" >&2
    fi
    sleep 1  # be polite to Flickr
  done < <(printf '%s' "$page_html" \
      | grep -oE 'live\.staticflickr\.com/[0-9]+/([0-9]+)_' \
      | sed -E 's|.*/([0-9]+)_$|\1|' | awk '!seen[$0]++')

  echo "   $count photos in $outdir"
done

echo "Done. Now run: python3 scripts/build-gallery.py"
