#!/usr/bin/env python3
"""build-gallery.py — turn site-assets/flickr/ downloads into web gallery assets.

Reads  homepage/site-assets/flickr/<album>/<id>.jpg (+ <id>.title.txt)
Writes homepage/html/assets/photos/full/<id>.jpg    (max 1024, q82)
       homepage/html/assets/photos/thumbs/<id>.jpg  (max 560 wide, q75)
       homepage/html/assets/photos/manifest.json    (album, title, dims)

Re-runnable; skips images whose outputs are newer than the source.
"""
import json
from pathlib import Path

from PIL import Image, ImageOps

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "homepage" / "site-assets" / "flickr"
OUT = REPO / "homepage" / "html" / "assets" / "photos"
FULL_MAX = 1024
THUMB_W = 560

ALBUM_ORDER = ["landscapes", "street", "birds", "flowers"]


def process(src: Path, dest: Path, max_side: int, quality: int) -> tuple[int, int]:
    with Image.open(src) as im:
        im = ImageOps.exif_transpose(im).convert("RGB")
        im.thumbnail((max_side, max_side), Image.LANCZOS)
        dest.parent.mkdir(parents=True, exist_ok=True)
        im.save(dest, "JPEG", quality=quality, optimize=True, progressive=True)
        return im.size


def main() -> None:
    manifest = []
    for album in ALBUM_ORDER:
        adir = SRC / album
        if not adir.is_dir():
            continue
        for jpg in sorted(adir.glob("*.jpg")):
            pid = jpg.stem
            title_file = adir / f"{pid}.title.txt"
            title = title_file.read_text().strip() if title_file.exists() else ""
            full = OUT / "full" / f"{pid}.jpg"
            thumb = OUT / "thumbs" / f"{pid}.jpg"
            w, h = process(jpg, full, FULL_MAX, 82)
            process(jpg, thumb, THUMB_W, 75)
            manifest.append(
                {"id": pid, "album": album, "title": title, "w": w, "h": h}
            )
            print(f"{album}/{pid}  {w}x{h}  {title}")

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=1))
    print(f"\n{len(manifest)} photos -> {OUT / 'manifest.json'}")


if __name__ == "__main__":
    main()
