#!/usr/bin/env python3
"""Add an independently verified public archive to a single app's stable feed."""

import argparse
import hashlib
import json
import re
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-json", type=Path, required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--minimum-macos", required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--feed", type=Path, required=True)
    parser.add_argument("--tag-prefix", default="")
    args = parser.parse_args()

    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        parser.error("invalid repository")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", args.minimum_macos):
        parser.error("invalid macOS minimum")

    release = json.loads(args.release_json.read_text())
    tag = release["tag_name"]
    if (release.get("draft") or release.get("prerelease")
            or not re.fullmatch(re.escape(args.tag_prefix) + r"v[0-9]+(?:\.[0-9]+){2}", tag)):
        parser.error("expected a public stable tag for this app")

    archive_name = args.archive.name
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.(zip|dmg)", archive_name):
        parser.error("expected a ZIP or DMG asset")
    url = f"https://github.com/{args.repository}/releases/download/{tag}/{archive_name}"
    with args.archive.open("rb") as archive:
        digest = "sha256:" + hashlib.file_digest(archive, "sha256").hexdigest()
    if not any(asset.get("browser_download_url") == url and asset.get("digest") == digest
               for asset in release["assets"]):
        parser.error("GitHub's public asset URL or digest does not match the verified archive")

    entry = {key: release[key] for key in ("tag_name", "body", "published_at", "html_url")}
    entry["minimum_macos"] = args.minimum_macos
    entry["assets"] = [{"name": archive_name, "browser_download_url": url, "digest": digest}]
    feed = json.loads(args.feed.read_text()) if args.feed.exists() else []
    if any(prior["tag_name"] == tag and prior["assets"] != entry["assets"] for prior in feed):
        parser.error("the existing public tag points to different bytes; publish a new version")
    feed = [prior for prior in feed if prior["tag_name"] != tag] + [entry]
    feed.sort(key=lambda item: tuple(map(int, item["tag_name"][len(args.tag_prefix) + 1:].split("."))), reverse=True)
    args.feed.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=args.feed.parent, delete=False) as output:
        json.dump(feed[:10], output, indent=2)
        output.write("\n")
    Path(output.name).replace(args.feed)


if __name__ == "__main__":
    main()
