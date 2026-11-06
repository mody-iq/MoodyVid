#!/usr/bin/env python3
"""Adds Python, the standard library and yt-dlp to the compiled MoodyVid.app.

Adapted from VidGrab's assemble.py (GPL-3.0, by T4MAG0).

Usage:
  python3 scripts/assemble.py --app build/Payload/MoodyVid.app \
      --xcframework build/pyfw/Python.xcframework \
      --packages build/app_packages \
      --ytdlp build/yt-dlp \
      --bundle-id com.mody.moodyvid
"""
import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

DROP_STDLIB = {'test', 'idlelib', 'tkinter', 'turtledemo', 'ensurepip', 'pydoc_data',
               '__phello__', 'turtle.py', 'lib2to3', 'venv'}
DROP_DYNLOAD_PREFIX = ('_test', '_ctypes_test', 'xx', '_xxtestfuzz', '_remote_debugging')

LDID = shutil.which('ldid')


def run(*cmd, check=True):
    return subprocess.run(cmd, check=check)


def sign(path):
    """Ad-hoc signature. The sideloading tool re-signs everything with your certificate."""
    if LDID:
        run(LDID, '-S', path)
    else:
        run('codesign', '--force', '--sign', '-', path)


def fail(message):
    print(f'ERROR: {message}', file=sys.stderr)
    sys.exit(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--app', required=True)
    ap.add_argument('--xcframework', required=True)
    ap.add_argument('--packages', required=True)
    ap.add_argument('--ytdlp', required=True)
    ap.add_argument('--bundle-id', required=True)
    args = ap.parse_args()

    app = os.path.abspath(args.app)
    xc = os.path.abspath(args.xcframework)
    slice_dir = os.path.join(xc, 'ios-arm64')
    py_ver = f'python{sys.version_info.major}.{sys.version_info.minor}'

    if not os.path.isdir(slice_dir):
        fail(f'ios-arm64 slice not found in {xc}. Contents: {os.listdir(xc) if os.path.isdir(xc) else "missing"}')
    if not os.path.isdir(os.path.join(slice_dir, 'lib-arm64', py_ver)):
        fail(f'{py_ver} not found in the Python support package. This script needs the same '
             f'Python minor version as the package. Found: {os.listdir(os.path.join(slice_dir, "lib-arm64"))}')
    print(f'Using {py_ver}, signer: {"ldid" if LDID else "codesign"}')

    # 1. Python.framework (no headers needed at runtime)
    fw = os.path.join(app, 'Frameworks')
    os.makedirs(fw, exist_ok=True)
    shutil.copytree(os.path.join(slice_dir, 'Python.framework'), os.path.join(fw, 'Python.framework'),
                    ignore=shutil.ignore_patterns('Headers'))

    # 2. Standard library: shared part + arm64 part, trimmed
    lib = os.path.join(app, 'python', 'lib')
    shutil.copytree(os.path.join(xc, 'lib'), lib,
                    ignore=lambda d, names: [n for n in names if n in DROP_STDLIB or n == '__pycache__'
                                             or n.startswith('libpython')])
    shutil.copytree(os.path.join(slice_dir, 'lib-arm64'), lib, dirs_exist_ok=True,
                    ignore=lambda d, names: [n for n in names if n.startswith(DROP_DYNLOAD_PREFIX)
                                             or n.startswith('libpython')])
    for root, dirs, _ in os.walk(lib):
        for d in list(dirs):
            if d in ('tests', 'idle_test'):
                shutil.rmtree(os.path.join(root, d))
                dirs.remove(d)

    # 3. App code and packages
    app_code = os.path.join(app, 'app')
    shutil.copytree(os.path.join(ROOT, 'app'), app_code, ignore=shutil.ignore_patterns('__pycache__'))
    pk = os.path.join(app, 'app_packages')
    if os.path.isdir(args.packages):
        shutil.copytree(args.packages, pk, ignore=shutil.ignore_patterns('__pycache__'))
    else:
        os.makedirs(pk)
    with zipfile.ZipFile(args.ytdlp) as z:
        names = [n for n in z.namelist() if n.startswith(('yt_dlp/', 'yt_dlp_ejs/'))]
        for n in names:
            z.extract(n, pk)
    if not os.path.isfile(os.path.join(pk, 'yt_dlp', 'version.py')):
        fail('yt-dlp was not found inside the downloaded file')
    print(f'yt-dlp files extracted: {len(names)}; EJS included: '
          f'{os.path.isdir(os.path.join(pk, "yt_dlp_ejs"))}')

    # 4. Precompile so the app does not compile Python on every launch (the bundle is read-only)
    flags = ['-m', 'compileall', '-q', '-j0', '--invalidation-mode', 'unchecked-hash']
    run(sys.executable, *flags, app_code)
    for d in (lib, pk):
        r = run(sys.executable, *flags, d, check=False)
        if r.returncode != 0:
            print(f'WARNING: some files in {d} did not precompile (not fatal)')

    # 5. Convert every .so into Frameworks/<module>.framework, as iOS requires
    template_path = os.path.join(xc, 'build', 'iOS-dylib-Info-template.plist')
    if os.path.isfile(template_path):
        with open(template_path, 'rb') as f:
            template = plistlib.load(f)
    else:
        print('WARNING: Info.plist template not found, using a built-in one')
        template = {'CFBundleDevelopmentRegion': 'en', 'CFBundlePackageType': 'FMWK',
                    'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleVersion': '1',
                    'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '13.0',
                    'CFBundleSupportedPlatforms': ['iPhoneOS']}
    count = 0
    for base in (os.path.join(lib, py_ver, 'lib-dynload'), pk):
        for root, _, files in os.walk(base):
            for name in files:
                if not name.endswith('.so'):
                    continue
                full = os.path.join(root, name)
                rel = os.path.relpath(full, base)
                module = rel.split('.')[0].replace(os.sep, '.')
                fdir = os.path.join(fw, f'{module}.framework')
                os.makedirs(fdir, exist_ok=True)
                info = dict(template, CFBundleExecutable=module,
                            CFBundleIdentifier=f'{args.bundle_id}.{module}'.replace('_', '-'))
                with open(os.path.join(fdir, 'Info.plist'), 'wb') as f:
                    plistlib.dump(info, f)
                shutil.move(full, os.path.join(fdir, module))
                with open(full[:-3] + '.fwork', 'w') as f:
                    f.write(f'Frameworks/{module}.framework/{module}')
                with open(os.path.join(fdir, f'{module}.origin'), 'w') as f:
                    f.write(os.path.relpath(full, app)[:-3] + '.fwork')
                count += 1
    print(f'Converted {count} extension modules to frameworks')

    # 6. Sign frameworks, then the main executable
    for name in sorted(os.listdir(fw)):
        if name.endswith('.framework'):
            sign(os.path.join(fw, name, name[:-len('.framework')]))
    with open(os.path.join(app, 'Info.plist'), 'rb') as f:
        exe = plistlib.load(f)['CFBundleExecutable']
    sign(os.path.join(app, exe))

    # 7. Everything must be readable by the phone's normal user
    for r, ds, fs in os.walk(app):
        for n in ds + fs:
            p = os.path.join(r, n)
            if not os.path.islink(p):
                os.chmod(p, os.stat(p).st_mode | 0o444 | (0o111 if os.path.isdir(p) else 0))

    print('Assemble finished.')


if __name__ == '__main__':
    sys.exit(main())
