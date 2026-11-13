#!/usr/bin/env python3
"""Check whether a build still represents the code at the current main tip.

Only README/docs and LICENSE changes can safely land after a build without
requiring another build. A source.json change is NOT ignored here: it can mean
another run has already published a newer artifact from the same code.
"""
import argparse
import subprocess
import sys


def _git(*args):
    return subprocess.run(["git", *args], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def is_publishable(built_revision, current_revision):
    ancestor = _git("merge-base", "--is-ancestor", built_revision, current_revision)
    if ancestor.returncode == 1:
        return False
    if ancestor.returncode:
        raise RuntimeError(ancestor.stderr.decode(errors="replace").strip() or "git merge-base failed")
    result = _git("diff", "--name-only", "--no-renames", "-z", built_revision, current_revision, "--")
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace").strip() or "git diff failed")
    paths = [p.decode("utf-8", errors="surrogateescape") for p in result.stdout.split(b"\0") if p]
    return all(path == "LICENSE" or path.endswith(".md") for path in paths)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("built_revision")
    parser.add_argument("current_revision")
    args = parser.parse_args(argv)
    try:
        return 0 if is_publishable(args.built_revision, args.current_revision) else 1
    except RuntimeError as exc:
        print(f"Cannot check publication revision: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
