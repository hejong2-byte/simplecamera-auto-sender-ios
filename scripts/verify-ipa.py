import argparse
import plistlib
import zipfile
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    args = parser.parse_args()

    with zipfile.ZipFile(args.ipa) as archive:
        if archive.testzip() is not None:
            raise SystemExit("IPA archive is damaged")
        info = plistlib.loads(
            archive.read("Payload/SimpleCameraAutoSender.app/Info.plist")
        )

    for key in ("UIFileSharingEnabled", "LSSupportsOpeningDocumentsInPlace"):
        if info.get(key) is not True:
            raise SystemExit(f"Built IPA must enable {key}")

    print("Built IPA Files visibility: OK")


if __name__ == "__main__":
    main()
