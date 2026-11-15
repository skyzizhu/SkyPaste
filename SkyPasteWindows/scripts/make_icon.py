#!/usr/bin/env python3
"""Generate Assets/icon.ico from the macOS app icon PNG (dependency-free).

Resizes with macOS `sips`, then packs resized PNGs into an ICO container
(PNG payloads are valid ICO entries on Windows Vista and later).
"""
import os
import struct
import subprocess
import sys
import tempfile

SOURCE = os.environ.get(
    "ICON_SOURCE",
    os.path.join(os.path.dirname(__file__), "..", "..", "skypaste", "Assets.xcassets", "AppIcon.appiconset", "icon_512x512@2x.png"),
)
SIZES = [256, 128, 64, 48, 32, 16]


def resize_png(source: str, size: int, dest: str) -> None:
    subprocess.run(["sips", "-z", str(size), str(size), source, "--out", dest], check=True, capture_output=True)


def pack_ico(png_paths: dict, dest: str) -> None:
    # ICONDIR + ICONDIRENTRY per image + payloads
    header = struct.pack("<HHH", 0, 1, len(png_paths))
    entries = b""
    payloads = b""
    offset = 6 + 16 * len(png_paths)
    for size in sorted(png_paths, reverse=True):
        data = png_paths[size]
        w = 0 if size >= 256 else size
        h = 0 if size >= 256 else size
        entries += struct.pack(
            "<BBBBHHII", w, h, 0, 0, 1, 32, len(data), offset
        )
        payloads += data
        offset += len(data)
    with open(dest, "wb") as f:
        f.write(header + entries + payloads)


def main() -> int:
    source = os.path.abspath(SOURCE)
    if not os.path.exists(source):
        print(f"source icon not found: {source}", file=sys.stderr)
        return 1
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "SkyPaste", "Assets")
    out_dir = os.path.abspath(out_dir)
    os.makedirs(out_dir, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        payloads = {}
        for size in SIZES:
            dest = os.path.join(tmp, f"icon_{size}.png")
            resize_png(source, size, dest)
            with open(dest, "rb") as f:
                payloads[size] = f.read()
        dest_ico = os.path.join(out_dir, "icon.ico")
        pack_ico(payloads, dest_ico)
        print(f"wrote {dest_ico} ({os.path.getsize(dest_ico)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
