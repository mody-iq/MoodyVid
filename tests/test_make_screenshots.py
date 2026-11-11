"""Tests for the store-screenshot generator.

The screenshots are mockups drawn by code, so the failure mode is silent: a
string that overflows its card, or content that slides under the tab bar, still
produces a valid PNG. These tests run the real drawing code and assert the
layout invariants instead of trusting the eye.

Run with: python3 -m unittest tests.test_make_screenshots -v
"""
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

try:
    from PIL import Image
except ImportError:
    Image = None

if Image is not None:
    import make_screenshots as ms


@unittest.skipIf(Image is None, "Pillow not installed")
class ScreenshotTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def render(self, screen_fn):
        path = os.path.join(self.tmp, screen_fn.__name__ + ".png")
        screen_fn().save(path)
        return path

    def test_every_screen_renders_at_the_expected_size(self):
        for name, fn, caption in ms.SCREENS:
            with self.subTest(screen=name):
                path = self.render(fn)
                with Image.open(path) as im:
                    self.assertEqual(im.size, (1290, 2796))
                self.assertTrue(caption)

    def test_index_covers_every_screen(self):
        ms.main(["--out-dir", self.tmp])
        import json
        with open(os.path.join(self.tmp, "index.json"), encoding="utf-8") as fh:
            index = json.load(fh)
        self.assertEqual(len(index), len(ms.SCREENS))
        for entry, (name, _, _) in zip(index, ms.SCREENS):
            self.assertEqual(entry["file"], name)
            self.assertTrue(os.path.isfile(os.path.join(self.tmp, name)))

    def test_content_never_runs_under_the_tab_bar(self):
        # need() raises on overflow; rendering at all is the assertion. This test
        # exists so a future edit that removes the check fails loudly here.
        for name, fn, _ in ms.SCREENS:
            with self.subTest(screen=name):
                screen = fn()
                self.assertLessEqual(screen.y, screen.limit)

    def test_overflow_is_actually_caught(self):
        # Prove the guard works rather than trusting that it does.
        s = ms.Screen("probe")
        s.at(ms.CONTENT_BOTTOM - 10)
        with self.assertRaises(AssertionError):
            s.need(100)

    def test_screens_are_not_mostly_empty(self):
        # A screen with a third of the height blank reads as broken. The tallest
        # content block must reach a reasonable way down the content area.
        limit = ms.CONTENT_BOTTOM
        for name, fn, _ in ms.SCREENS:
            with self.subTest(screen=name):
                path = self.render(fn)
                with Image.open(path).convert("L") as im:
                    px = im.load()
                    last = 0
                    for y in range(0, limit, 3):
                        if any(px[x, y] > 24 for x in range(0, im.width, 6)):
                            last = y
                self.assertGreater(last / limit, 0.55,
                                   f"{name} is only {last / limit:.0%} full")

    def test_arabic_is_shaped_not_dropped(self):
        # If the font has no Arabic, Pillow draws boxes; the page would look
        # broken in a way no size check catches.
        font = ms.load_font(ms.pt(14))
        width = font.getlength("جودة الفيديو", direction="rtl", language="ar")
        self.assertGreater(width, 10)


if __name__ == "__main__":
    unittest.main()
