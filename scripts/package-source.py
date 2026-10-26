#!/usr/bin/env python3
"""Stage auditable RC source with pinned SDKs and authorised artwork, excluding outputs, preferences and logs."""
from pathlib import Path
import argparse
import hashlib
import io
import json
import plistlib
import re
import tarfile


ROOT = Path(__file__).resolve().parents[1]
ARTWORK = {"Resources/ThemeAssets/IconPearl.png", "Resources/ThemeAssets/MilkFrog.png"}
TREES = ("Sources", "Resources", "Tests", "scripts", "Bridge/App", "Bridge/Plugin", "Bridge/Tests", "Bridge/Tools",
         "Bridge/scripts", "Bridge/ThirdParty")
FILES = (".gitignore", "Package.swift", "README.md", "COPYRIGHT.md", "LICENSE", "RELEASE_NOTES.md",
         "Bridge/README.md", "Bridge/ARCHITECTURE.md", "Bridge/PROTOCOL.md", "Bridge/THIRD_PARTY_NOTICES.md",
         "docs/INSTALLATION.md", "docs/THIRD_PARTY_NOTICES.md", "docs/LOUDNESS_REFERENCES.md",
         "docs/SPEAKER_LAYOUT_FORMAT.md", "docs/ASSET_RIGHTS.md", "docs/SOURCE_DISTRIBUTION.md",
         "docs/2.0_RC3_RELEASE_NOTES.md", "docs/2.0_RC2_RELEASE_NOTES.md", "docs/MULTIFFT_ARCHITECTURE.md", "docs/2.0_RC1_RELEASE_NOTES.md", "docs/UPDATE_LOG_since_1.2.2.md")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--without-supplied-artwork", action="store_true",
                        help="Omit optional theme images to verify the gradient fallback; normal source includes both images.")
    args = parser.parse_args()
    info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    build = info["CFBundleVersion"]
    # "2.0 rc 3" → "2.0-rc3": the archive is named after the release label.
    prefix = f"Auraliscope-{info['AuraliscopeVersionLabel'].replace(' rc ', '-rc').replace(' ', '-')}-build{build}"
    paths = set(ROOT / name for name in FILES)
    for name in TREES:
        paths.update(p for p in (ROOT / name).rglob("*") if p.is_file())
    missing = [p.relative_to(ROOT).as_posix() for p in paths if not p.is_file()]
    if missing:
        raise SystemExit("Missing source files: " + ", ".join(sorted(missing)))
    paths = sorted(p for p in paths if not any(part.startswith("._") or part in {".DS_Store", ".git", "__pycache__"}
                   for part in p.relative_to(ROOT).parts) and p.suffix != ".pyc"
                   and (not args.without_supplied_artwork or p.relative_to(ROOT).as_posix() not in ARTWORK))
    pins = {}
    pin_text = (ROOT / "Bridge/scripts/fetch-sdks.sh").read_text()
    for destination, repo, commit in re.findall(r'(vst3sdk/\S+|AudioUnitSDK)\s+"(\S+) ([0-9a-f]{40})"', pin_text):
        pinned = ROOT / "Bridge/ThirdParty" / destination / ".pinned"
        if not pinned.is_file() or pinned.read_text().strip() != commit:
            raise SystemExit(f"Fetch the pinned SDK before packaging: {destination}")
        pins[destination] = {"repository": repo, "commit": commit}
    if len(pins) != 4:
        raise SystemExit("Expected four pinned SDK source trees")
    manifest = "".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(ROOT).as_posix()}\n" for p in paths)
    metadata = {
        "version": info["AuraliscopeVersionLabel"], "build": build,
        "source_files": len(paths), "project_license": "GPL-3.0-only", "sdk_pins": pins,
        "supplied_artwork_included": not args.without_supplied_artwork,
        "excluded_artwork": sorted(ARTWORK) if args.without_supplied_artwork else [],
        "image_rights": "Pearl: owner-confirmed public redistribution; Milk Frog: public domain per owner. See docs/ASSET_RIGHTS.md.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(args.output, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        def add(name, data, executable=False):
            item = tarfile.TarInfo(f"{prefix}/{name}")
            item.size = len(data)
            item.mode = 0o755 if executable else 0o644
            archive.addfile(item, io.BytesIO(data))
        for p in paths:
            add(p.relative_to(ROOT).as_posix(), p.read_bytes(), p.suffix in {".sh", ".py"})
        add("SOURCE_MANIFEST.sha256", manifest.encode())
        add("SOURCE_INFO.json", (json.dumps(metadata, indent=2, ensure_ascii=False) + "\n").encode())
    # Verify every saved source byte, and that no omitted artwork slipped in.
    with tarfile.open(args.output) as archive:
        for line in manifest.splitlines():
            digest, name = line.split("  ", 1)
            if hashlib.sha256(archive.extractfile(f"{prefix}/{name}").read()).hexdigest() != digest:
                raise SystemExit(f"Archive mismatch: {name}")
        for name in ARTWORK:
            present = f"{prefix}/{name}" in archive.getnames()
            if present == args.without_supplied_artwork:
                raise SystemExit(f"Unexpected supplied artwork inclusion: {name}")
    print(f"PASS: {len(paths)} source files and four pinned SDK trees; source bytes verified: {args.output}")


if __name__ == "__main__":
    main()
