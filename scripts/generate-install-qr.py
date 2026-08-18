import argparse
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse


ROOT = Path(__file__).resolve().parents[1]
PAYLOAD_FILE = ROOT / "install-url.txt"
EXPECTED_REPOSITORY = "/hejong2-byte/simplecamera-auto-sender-ios/"
EXPECTED_ASSET = "/releases/latest/download/SimpleCameraAutoSender.ipa"


def validated_payload() -> str:
    payload = PAYLOAD_FILE.read_text(encoding="utf-8").strip()
    parsed = urlparse(payload)
    if parsed.scheme != "sidestore" or parsed.netloc != "install":
        raise ValueError("SideStore install URI is invalid")

    query = parse_qs(parsed.query)
    if set(query) != {"url"} or len(query["url"]) != 1:
        raise ValueError("SideStore URI must contain exactly one url value")

    download_url = urlparse(unquote(query["url"][0]))
    if download_url.scheme != "https" or download_url.netloc != "github.com":
        raise ValueError("Download must use GitHub HTTPS")
    if EXPECTED_REPOSITORY not in download_url.path:
        raise ValueError("Unexpected GitHub repository")
    if not download_url.path.endswith(EXPECTED_ASSET):
        raise ValueError("Unexpected IPA release asset")
    return payload


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    payload = validated_payload()

    if args.output:
        import qrcode

        qr = qrcode.QRCode(
            version=None,
            error_correction=qrcode.constants.ERROR_CORRECT_H,
            box_size=12,
            border=4,
        )
        qr.add_data(payload)
        qr.make(fit=True)
        image = qr.make_image(fill_color="black", back_color="white")
        output = args.output if args.output.is_absolute() else ROOT / args.output
        output.parent.mkdir(parents=True, exist_ok=True)
        image.save(output)

    if args.check:
        print("SideStore install URI: valid")


if __name__ == "__main__":
    main()
