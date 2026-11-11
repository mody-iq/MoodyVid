#!/usr/bin/env python3
"""Writes the AltStore/SideStore source file for MoodyVid.

An AltStore "source" is a small JSON file a user adds once in the app; from then
on the app lists MoodyVid, installs it, and offers every later version as an
update. That is the whole point of this file: it turns a GitHub Release asset
into one tap for a non-technical user.

The CI calls this after the IPA is built and attached to a release, then commits
the result back to the repository so the raw URL stays stable.

Usage:
  python3 scripts/make_source.py --ipa build/MoodyVid.ipa --version 0.2.0 \
      --build 42 --download-url https://github.com/.../MoodyVid.ipa \
      --out source.json --icon-url https://raw.githubusercontent.com/.../icon.png \
      --size 24500000 --notes "What changed"
"""
import argparse
import datetime
import json
import os
import sys


def parse_args(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--ipa', required=True, help='built .ipa, read to confirm it exists')
    ap.add_argument('--version', required=True, help='CFBundleShortVersionString, e.g. 0.2.0')
    ap.add_argument('--build', required=True, help='CFBundleVersion, an increasing integer')
    ap.add_argument('--download-url', required=True, help='public URL of the .ipa')
    ap.add_argument('--icon-url', required=True, help='public URL of a 1024x1024 PNG')
    ap.add_argument('--size', type=int, required=True, help='IPA size in bytes')
    ap.add_argument('--bundle-id', default='com.mody.moodyvid')
    ap.add_argument('--name', default='MoodyVid')
    ap.add_argument('--subtitle', default='تنزيل الفيديو من أي موقع')
    ap.add_argument('--description', default=None)
    ap.add_argument('--notes', default='')
    ap.add_argument('--out', required=True)
    ap.add_argument('--min-os', default='15.0')
    ap.add_argument('--max-os', default=None,
                    help='newest iOS the app is known to run on, if any')
    ap.add_argument('--device', default='iPhone',
                    help='devices the app runs on; iPhone only, so AltStore hides '
                         'it on an iPad instead of installing something unusable')
    ap.add_argument('--screenshots-index', default=None,
                    help='screenshots/index.json written by make_screenshots.py')
    ap.add_argument('--screenshot-base-url', default=None,
                    help='public URL prefix the screenshot files live under')
    return ap.parse_args(argv)


def load_screenshots(index_path, base_url):
    """Builds the AltStore screenshot list from the generator's index.

    AltStore shows these in the app's page before install. Missing files or a
    missing base URL are not fatal: a source with no images still works, it just
    looks plain, and failing the release over a cosmetic file would be worse.
    """
    if not index_path or not base_url:
        return []
    if not os.path.isfile(index_path):
        print(f'WARNING: screenshot index not found: {index_path}', file=sys.stderr)
        return []
    try:
        with open(index_path, encoding='utf-8') as fh:
            entries = json.load(fh)
    except (OSError, ValueError) as exc:
        print(f'WARNING: cannot read {index_path}: {exc}', file=sys.stderr)
        return []

    shots = []
    for entry in entries:
        name = entry.get('file')
        if not name:
            continue
        url = f'{base_url.rstrip("/")}/{name}'
        # AltStore needs the pixel size up front to lay the image out.
        try:
            from PIL import Image
            path = os.path.join(os.path.dirname(index_path), name)
            with Image.open(path) as im:
                width, height = im.size
        except Exception:
            width, height = 1290, 2796
        shot = {'imageURL': url, 'width': width, 'height': height}
        if entry.get('caption'):
            shot['caption'] = entry['caption']
        shots.append(shot)
    return shots


def main(argv):
    args = parse_args(argv)

    if not os.path.isfile(args.ipa):
        print(f'ERROR: IPA not found: {args.ipa}', file=sys.stderr)
        return 1

    # AltStore compares buildVersion to decide whether to offer an update, so it
    # has to be monotonic. The workflow run number is; the version string alone is
    # not (two builds of 0.2.0 are indistinguishable).
    #
    # Only the newest version is kept: downloadURL always points at the rolling
    # "latest" release asset, so an older entry would just re-download the same
    # file. A single entry keeps the file small and impossible to get wrong.
    version = {
        'version': args.version,
        'buildVersion': str(args.build),
        'date': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'downloadURL': args.download_url,
        'size': args.size,
        'minOSVersion': args.min_os,
        'localizedDescription': args.notes or f'{args.name} {args.version}',
    }
    if args.max_os:
        version['maxOSVersion'] = args.max_os

    app = {
        'name': args.name,
        'bundleIdentifier': args.bundle_id,
        'developerName': args.name,
        'subtitle': args.subtitle,
        'localizedDescription': args.description or args.subtitle,
        'iconURL': args.icon_url,
        'tintColor': '12ACBA',
        'category': 'utilities',
        'screenshots': load_screenshots(args.screenshots_index,
                                        args.screenshot_base_url),
        'versions': [version],
        # AltStore reads this and hides the app on a device it cannot run on,
        # which beats a failed install with no explanation.
        'deviceFamilies': [args.device],
        'appPermissions': {
            'entitlements': [],
            'privacy': {
                'NSPhotoLibraryAddUsageDescription':
                    'يحتاج التطبيق إلى إذن الصور لحفظ الفيديوهات التي تم تحميلها.',
                'NSPhotoLibraryUsageDescription':
                    'يحتاج التطبيق إلى إذن الصور لحفظ الفيديوهات التي تم تحميلها.',
            },
        },
    }

    source = {
        'name': args.name,
        'identifier': f'{args.bundle_id}.source',
        'subtitle': args.subtitle,
        'description': args.description or args.subtitle,
        'iconURL': args.icon_url,
        'headerURL': args.icon_url,
        'tintColor': '12ACBA',
        'featuredApps': [args.bundle_id],
        'apps': [app],
        'news': [],
    }

    with open(args.out, 'w', encoding='utf-8') as fh:
        json.dump(source, fh, ensure_ascii=False, indent=2)
        fh.write('\n')

    print(f'source written: {args.out} ({args.version} build {args.build})')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
