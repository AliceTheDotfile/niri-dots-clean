#!/usr/bin/env python3

import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("missing Pillow. install it with: sudo pacman -S python-pillow")
    sys.exit(1)


def extract_palette(path: str, colors: int = 10) -> list[str]:
    image = Image.open(path).convert("RGB")

    # Shrink first so huge wallpapers don't take forever.
    image.thumbnail((256, 256))

    # Pillow's quantizer gives us a compact dominant-color palette.
    quantized = image.quantize(colors=colors, method=Image.Quantize.MEDIANCUT)

    palette = quantized.getpalette()
    color_counts = quantized.getcolors()

    if not color_counts:
        return []

    # Most common colors first.
    color_counts.sort(reverse=True)

    result = []

    for _, index in color_counts:
        r = palette[index * 3]
        g = palette[index * 3 + 1]
        b = palette[index * 3 + 2]

        hex_color = f"#{r:02X}{g:02X}{b:02X}"

        if hex_color not in result:
            result.append(hex_color)

    return result[:colors]


def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} IMAGE [COLORS]")
        sys.exit(1)

    image = Path(sys.argv[1])

    if not image.is_file():
        print(f"error: file not found: {image}")
        sys.exit(1)

    try:
        colors = int(sys.argv[2]) if len(sys.argv) > 2 else 10
    except ValueError:
        print("error: COLORS must be a number")
        sys.exit(1)

    colors = max(1, min(colors, 256))

    for color in extract_palette(str(image), colors):
        print(color)


if __name__ == "__main__":
    main()
