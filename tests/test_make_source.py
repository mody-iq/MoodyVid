"""Tests for the AltStore source generator.

`source.json` is what a non-technical user pastes into AltStore once, and it is
the difference between "download this file and figure out signing" and "tap
Install". A wrong field does not fail loudly: AltStore simply shows nothing, or
installs a stale build. These tests pin the fields that matter.

Run with: python3 -m unittest tests.test_make_source -v
"""
import json
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

import make_source  # noqa: E402


class MakeSourceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.ipa = os.path.join(self.tmp, "MoodyVid.ipa")
        with open(self.ipa, "wb") as fh:
            fh.write(b"PK\x03\x04 not really an ipa, but present")
        self.out = os.path.join(self.tmp, "source.json")

    def build(self, **overrides):
        args = {
            "ipa": self.ipa,
            "version": "0.2.0",
            "build": "42",
            "download_url": "https://github.com/o/r/releases/download/latest/MoodyVid.ipa",
            "icon_url": "https://raw.githubusercontent.com/o/r/main/Resources/icon-source.png",
            "size": 24500000,
            "out": self.out,
        }
        args.update(overrides)
        argv = ["--" + k.replace("_", "-") + "=" + str(v) for k, v in args.items()]
        rc = make_source.main(argv)
        self.assertEqual(rc, 0)
        with open(self.out, encoding="utf-8") as fh:
            return json.load(fh)

    def test_bundle_id_matches_the_app(self):
        # AltStore keys installs on this. A mismatch means the source lists an app
        # that can never replace the one already installed.
        source = self.build()
        self.assertEqual(source["apps"][0]["bundleIdentifier"], "com.mody.moodyvid")
        self.assertIn("com.mody.moodyvid", source["featuredApps"])

    def test_build_version_is_monotonic_input(self):
        # AltStore compares buildVersion to decide "update available". It must be
        # the run number, not the version string, or two builds of 0.2.0 tie.
        source = self.build(build="43")
        self.assertEqual(source["apps"][0]["versions"][0]["buildVersion"], "43")

    def test_download_url_is_carried_through(self):
        source = self.build()
        self.assertTrue(
            source["apps"][0]["versions"][0]["downloadURL"].endswith("MoodyVid.ipa")
        )

    def test_arabic_text_is_kept_readable(self):
        # ensure_ascii=False: the file is read by AltStore, and a user reading the
        # raw URL should see Arabic rather than a wall of \u escapes.
        self.build()
        with open(self.out, encoding="utf-8") as fh:
            raw = fh.read()
        self.assertIn("تنزيل", raw)

    def test_compatibility_is_stated_explicitly(self):
        # The user's question was "can I tell if it runs on my device?". minOSVersion
        # makes AltStore refuse the install on an older iOS, and deviceFamilies
        # hides it on an iPad, since the app is iPhone-only.
        source = self.build()
        self.assertEqual(source["apps"][0]["versions"][0]["minOSVersion"], "15.0")
        self.assertEqual(source["apps"][0]["deviceFamilies"], ["iPhone"])

    def test_missing_ipa_fails_instead_of_writing_a_dead_link(self):
        rc = make_source.main([
            "--ipa", os.path.join(self.tmp, "nope.ipa"),
            "--version", "0.2.0", "--build", "1",
            "--download-url", "https://x/y.ipa",
            "--icon-url", "https://x/i.png",
            "--size", "1", "--out", self.out,
        ])
        self.assertEqual(rc, 1)
        self.assertFalse(os.path.exists(self.out))

    def _index(self, entries):
        path = os.path.join(self.tmp, "index.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(entries, fh, ensure_ascii=False)
        return path

    def test_screenshots_are_listed_with_their_size(self):
        # AltStore lays the image out from width/height, so a shot without them
        # renders as a blank box. The size must come from the actual file.
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow not installed")
        shot = os.path.join(self.tmp, "01-home.png")
        Image.new("RGB", (1290, 2796)).save(shot)
        index = self._index([{"file": "01-home.png", "caption": "الشاشة الرئيسية"}])

        source = self.build(screenshots_index=index,
                            screenshot_base_url="https://cdn.example.com/shots")
        shots = source["apps"][0]["screenshots"]
        self.assertEqual(len(shots), 1)
        self.assertEqual(shots[0]["imageURL"], "https://cdn.example.com/shots/01-home.png")
        self.assertEqual(shots[0]["width"], 1290)
        self.assertEqual(shots[0]["height"], 2796)
        self.assertEqual(shots[0]["caption"], "الشاشة الرئيسية")

    def test_screenshot_url_has_no_double_slash(self):
        index = self._index([{"file": "a.png"}])
        source = self.build(screenshots_index=index,
                            screenshot_base_url="https://cdn.example.com/shots/")
        self.assertEqual(source["apps"][0]["screenshots"][0]["imageURL"],
                         "https://cdn.example.com/shots/a.png")

    def test_missing_screenshot_index_does_not_fail_the_release(self):
        # A cosmetic file must never block a build; the source just ships plain.
        source = self.build(screenshots_index=os.path.join(self.tmp, "nope.json"),
                            screenshot_base_url="https://cdn.example.com")
        self.assertEqual(source["apps"][0]["screenshots"], [])

    def test_no_screenshots_flag_means_no_screenshots(self):
        source = self.build()
        self.assertEqual(source["apps"][0]["screenshots"], [])


if __name__ == "__main__":
    unittest.main()
