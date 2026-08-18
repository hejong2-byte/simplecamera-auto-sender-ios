from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "design" / "icon-base.png"
OUTPUT = (
    ROOT
    / "App"
    / "Resources"
    / "Assets.xcassets"
    / "AppIcon.appiconset"
    / "AppIcon-1024.png"
)


def font(size: int) -> ImageFont.FreeTypeFont:
    candidates = [
        Path("C:/Windows/Fonts/malgunbd.ttf"),
        Path("/System/Library/Fonts/AppleSDGothicNeo.ttc"),
        Path("/System/Library/Fonts/Supplemental/Arial Bold.ttf"),
    ]
    for candidate in candidates:
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size=size)
    raise RuntimeError("Korean-capable bold font was not found")


def centered_text(
    draw: ImageDraw.ImageDraw,
    y: int,
    value: str,
    selected_font: ImageFont.FreeTypeFont,
    fill: tuple[int, int, int, int],
) -> None:
    bounds = draw.textbbox((0, 0), value, font=selected_font)
    width = bounds[2] - bounds[0]
    draw.text(((1024 - width) / 2, y), value, font=selected_font, fill=fill)


def main() -> None:
    image = Image.open(SOURCE).convert("RGB")
    image = ImageOps.fit(image, (1024, 1024), method=Image.Resampling.LANCZOS)
    overlay = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.rounded_rectangle(
        (66, 752, 958, 992),
        radius=48,
        fill=(0, 0, 0, 232),
        outline=(0, 220, 240, 255),
        width=5,
    )
    centered_text(draw, 776, "자동전송", font(90), (255, 255, 255, 255))
    centered_text(draw, 890, "ADD-ON", font(58), (0, 230, 245, 255))
    final = Image.alpha_composite(image.convert("RGBA"), overlay).convert("RGB")
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    final.save(OUTPUT, format="PNG", optimize=True)


if __name__ == "__main__":
    main()
