"""Write or verify Token Lens desktop release checksums and fetch draft assets."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tomllib


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = "SHA256SUMS.txt"
NUMBER = r"(?:0|[1-9][0-9]*)"
IDENTIFIER = r"(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
VERSION = rf"{NUMBER}\.{NUMBER}\.{NUMBER}(?:-{IDENTIFIER}(?:\.{IDENTIFIER})*)?"


def version_for_tag(tag):
    match = re.fullmatch(rf"v({VERSION})", tag)
    if not match:
        raise SystemExit("Tag must be v<semantic version>, without build metadata.")
    versions = re.findall(r"^version:\s*([^\s#]+)\s*(?:#.*)?$",
                          (ROOT / "app/pubspec.yaml").read_text(encoding="utf-8"), re.MULTILINE)
    if len(versions) != 1:
        raise SystemExit("Expected exactly one version in app/pubspec.yaml.")
    version = versions[0].split("+", 1)[0]
    cargo = tomllib.loads((ROOT / "app/rust/Cargo.toml").read_text(encoding="utf-8"))
    if cargo["package"]["version"] != version or match[1] != version:
        raise SystemExit(f"Tag and Rust package version must match pubspec version {version}.")
    return version


def archive_names(version):
    if not re.fullmatch(VERSION, version):
        raise SystemExit("Expected a semantic version without build metadata.")
    return sorted(f"token-lens-{version}-{platform}.zip" for platform in ("windows-x64", "macos"))


def require_names(actual, expected):
    if sorted(actual) != sorted(expected):
        raise SystemExit(f"Unexpected release attachments: expected {sorted(expected)}, got {sorted(actual)}.")


def release_checksums(directory, version, write=False):
    archives = archive_names(version)
    manifest = directory / MANIFEST
    entries = list(directory.iterdir())
    require_names([file.name for file in entries], archives if write else [*archives, MANIFEST])
    if any(file.is_symlink() or not file.is_file() for file in entries):
        raise SystemExit("Release attachments must be regular files.")
    lines = []
    for name in archives:
        with (directory / name).open("rb") as archive:
            lines.append(f"{hashlib.file_digest(archive, 'sha256').hexdigest()}  {name}\n")
    expected = "".join(lines).encode("ascii")
    if write:
        with manifest.open("xb") as output:
            output.write(expected)
    elif manifest.read_bytes() != expected:
        raise SystemExit(f"{MANIFEST} does not match the sorted SHA-256 checksums of the ZIPs.")


def gh_json(endpoint, *flags):
    return json.loads(subprocess.check_output(["gh", "api", *flags, endpoint]))


def download_draft(directory, release_id, source_sha):
    if not re.fullmatch(r"[1-9][0-9]*", release_id) or not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise SystemExit("Expected a positive numeric release ID and full source SHA.")
    releases = f"repos/{os.environ['GITHUB_REPOSITORY']}/releases"
    endpoint = f"{releases}/{release_id}"
    release = gh_json(endpoint)
    if release["id"] != int(release_id) or release["draft"] is not True:
        raise SystemExit("The requested release must be a draft.")
    tag = release["tag_name"]
    version = version_for_tag(tag)
    tag_commit = subprocess.check_output(
        ["git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}"], cwd=ROOT, text=True,
    ).strip()
    if tag_commit != source_sha:
        raise SystemExit(f"Release tag {tag} resolves to {tag_commit}, expected {source_sha}.")

    pages = gh_json(f"{endpoint}/assets?per_page=100", "--paginate", "--slurp")
    assets = [asset for page in pages for asset in page]
    require_names([asset["name"] for asset in assets], [*archive_names(version), MANIFEST])
    directory.mkdir()
    for asset in assets:
        asset_id = asset["id"]
        if asset["state"] != "uploaded" or type(asset_id) is not int or asset_id < 1:
            raise SystemExit(f"Invalid or incomplete release asset: {asset['name']}.")
        with (directory / asset["name"]).open("xb") as output:
            subprocess.run(["gh", "api", "-H", "Accept: application/octet-stream",
                            f"{releases}/assets/{asset_id}"], stdout=output, check=True)
    release_checksums(directory, version)
    return version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("version").add_argument("tag")
    for command in ("write", "check"):
        local = commands.add_parser(command)
        local.add_argument("directory", type=Path)
        local.add_argument("version")
    download = commands.add_parser("download")
    download.add_argument("directory", type=Path)
    download.add_argument("release_id")
    download.add_argument("source_sha")
    args = parser.parse_args()
    if args.command == "version":
        print(f"version={version_for_tag(args.tag)}")
    elif args.command == "download":
        print(f"version={download_draft(args.directory, args.release_id, args.source_sha)}")
    else:
        release_checksums(args.directory, args.version, write=args.command == "write")
        print(f"{'Wrote' if args.command == 'write' else 'Verified'} {MANIFEST}.")


if __name__ == "__main__":
    main()
