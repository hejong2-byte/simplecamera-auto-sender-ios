import re
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse


ROOT = Path(__file__).resolve().parents[1]


def project_bundle_identifier() -> str:
    project = (ROOT / "project.yml").read_text(encoding="utf-8")
    match = re.search(r"^\s*PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)\s*$", project, re.MULTILINE)
    if match is None:
        raise AssertionError("PRODUCT_BUNDLE_IDENTIFIER is missing from project.yml")
    return match.group(1)


def install_asset_stem() -> str:
    payload = (ROOT / "install-url.txt").read_text(encoding="utf-8").strip()
    parsed = urlparse(payload)
    query = parse_qs(parsed.query)
    download_url = urlparse(unquote(query["url"][0]))
    return Path(download_url.path).stem


def main() -> None:
    bundle_identifier = project_bundle_identifier()
    asset_stem = install_asset_stem()
    if asset_stem != bundle_identifier:
        raise AssertionError(
            "SideStore remote installs use the IPA filename as the expected bundle ID: "
            f"asset={asset_stem!r}, bundle={bundle_identifier!r}"
        )
    asset_name = f"{bundle_identifier}.ipa"
    for relative_path in (
        "scripts/build-unsigned-ipa.sh",
        "scripts/generate-install-qr.py",
        ".github/workflows/release.yml",
    ):
        contents = (ROOT / relative_path).read_text(encoding="utf-8")
        if asset_name not in contents:
            raise AssertionError(f"{relative_path} does not publish {asset_name}")
    print(f"SideStore release install contract: valid ({bundle_identifier})")


if __name__ == "__main__":
    main()
