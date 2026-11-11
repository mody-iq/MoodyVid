#!/usr/bin/env python3
"""Check that every [MVLang t:@"..."] key has an Arabic translation.

The app's strings live in one table in Sources/MVLang.m. A key missing from that
table silently falls back to English, which is easy to miss in Arabic. This
scans the sources for used keys and reports the ones the table does not cover,
plus any duplicate keys in the table.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"

# [MVLang t:@"Key"] and [MVLang t:@"Key" args:@[...]]
USE_RE = re.compile(r'\[MVLang\s+t:@?"((?:[^"\\]|\\.)*)"')
# A line in the table:  @"Key": @"Translation",
KEY_RE = re.compile(r'^\s*@"((?:[^"\\]|\\.)*)"\s*:', re.MULTILINE)


def unescape(s):
    return s.replace('\\"', '"').replace("\\n", "\n")


def main():
    lang_src = (SOURCES / "MVLang.m").read_text(encoding="utf-8")
    # Only the table literal, not the whole file, so the helper regexes do not
    # pick up unrelated @"..." literals.
    table_start = lang_src.find("static NSDictionary<NSString *, NSString *> *MVTable")
    table = lang_src[table_start:]

    defined = [unescape(m.group(1)) for m in KEY_RE.finditer(table)]
    defined_set = set(defined)

    used = set()
    for path in SOURCES.glob("*.m"):
        if path.name == "MVLang.m":
            continue
        for m in USE_RE.finditer(path.read_text(encoding="utf-8")):
            used.add(unescape(m.group(1)))

    missing = sorted(k for k in used if k not in defined_set)

    dupes = sorted({k for k in defined if defined.count(k) > 1})

    # Unused keys are only a warning: some are referenced from .py or by name.
    unused = sorted(k for k in defined_set if k not in used)

    fail = False
    if missing:
        fail = True
        print(f"MISSING ({len(missing)}) — used in code, absent from the table:")
        for k in missing:
            print(f"  {k}")
    if dupes:
        fail = True
        print(f"DUPLICATE KEYS ({len(dupes)}):")
        for k in dupes:
            print(f"  {k}")
    if not fail:
        print(f"OK: {len(used)} keys used, all present ({len(defined_set)} in the table).")
    if unused and "-v" in sys.argv:
        print(f"\nUnused table keys ({len(unused)}):")
        for k in unused:
            print(f"  {k}")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
