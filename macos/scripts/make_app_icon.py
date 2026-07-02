#!/usr/bin/env python3
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageOps


def rounded_rectangle_mask(size: int, box: tuple[int, int, int, int], radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(box, radius=radius, fill=255)
    return mask


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: make_app_icon.py input.jpg output.png", file=sys.stderr)
        return 2

    source = Path(sys.argv[1])
    output = Path(sys.argv[2])

    size = 1024
    card_box = (72, 64, 952, 944)
    card_radius = 176
    logo_size = 835
    logo_origin = ((size - logo_size) // 2, (size - logo_size) // 2)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        (card_box[0], card_box[1] + 16, card_box[2], card_box[3] + 16),
        radius=card_radius,
        fill=(0, 0, 0, 38),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(22))
    canvas.alpha_composite(shadow)

    card = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    card_mask = rounded_rectangle_mask(size, card_box, card_radius)
    canvas.paste(card, (0, 0), card_mask)

    logo = Image.open(source).convert("RGB")
    logo = ImageOps.fit(logo, (logo_size, logo_size), method=Image.Resampling.LANCZOS)
    logo_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    logo_layer.paste(logo.convert("RGBA"), logo_origin)
    logo_mask = ImageChops.multiply(logo_layer.getchannel("A"), card_mask)
    canvas.paste(logo_layer, (0, 0), logo_mask)

    border = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    border_draw = ImageDraw.Draw(border)
    border_draw.rounded_rectangle(card_box, radius=card_radius, outline=(0, 0, 0, 28), width=2)
    canvas.alpha_composite(border)

    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
