from pathlib import Path
from shutil import copyfile

from PIL import Image


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

def main() -> None:
    with Image.open(SOURCE) as image:
        if image.size != (1024, 1024):
            raise RuntimeError("App icon master must be exactly 1024x1024")
        if image.mode != "RGB":
            raise RuntimeError("App icon master must be opaque RGB")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    copyfile(SOURCE, OUTPUT)


if __name__ == "__main__":
    main()
