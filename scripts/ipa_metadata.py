#!/usr/bin/env python3
"""Validate the official IPA and emit safe GitHub Actions environment values.

The publication job consumes its own workflow's artifact, not the build
workspace. Refuse test bundle IDs, unexpected builds, malformed ZIPs/plists,
and values that could inject additional lines into GITHUB_ENV.
"""
import argparse
import os
import plistlib
import re
import sys
import zipfile
from pathlib import Path

INFO_PATH = "Payload/MoodyVid.app/Info.plist"
OFFICIAL_BUNDLE_ID = "com.mody.moodyvid"
_VERSION = re.compile(r"[0-9]+(?:\.[0-9]+){1,2}\Z")
_BUILD = re.compile(r"[0-9]+\Z")


def read_metadata(ipa_path, expected_build):
    path = Path(ipa_path)
    if not _BUILD.fullmatch(str(expected_build)):
        raise ValueError("invalid expected build number")
    with zipfile.ZipFile(path) as archive:
        if archive.namelist().count(INFO_PATH) != 1:
            raise ValueError("official app Info.plist missing or duplicated")
        info = plistlib.loads(archive.read(INFO_PATH))
    if info.get("CFBundleIdentifier") != OFFICIAL_BUNDLE_ID:
        raise ValueError("IPA does not have the official bundle ID")
    if info.get("CFBundleExecutable") != "MoodyVid":
        raise ValueError("IPA does not have the official executable name")
    if str(info.get("CFBundleVersion")) != str(expected_build):
        raise ValueError("IPA build number does not match this workflow run")
    version = info.get("CFBundleShortVersionString")
    min_os = info.get("MinimumOSVersion")
    if not isinstance(version, str) or not _VERSION.fullmatch(version):
        raise ValueError("invalid app version")
    if not isinstance(min_os, str) or not _VERSION.fullmatch(min_os):
        raise ValueError("invalid minimum iOS version")
    return {"VERSION": version, "MINOS": min_os, "SIZE": str(os.path.getsize(path))}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa")
    parser.add_argument("--expected-build", required=True)
    args = parser.parse_args(argv)
    try:
        result = read_metadata(args.ipa, args.expected_build)
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException, zipfile.BadZipFile) as exc:
        print(f"Cannot publish IPA: {exc}", file=sys.stderr)
        return 1
    for key, value in result.items():
        print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
