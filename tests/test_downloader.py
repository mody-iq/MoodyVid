"""Tests for the downloader's contract with the native layer.

These run on the build machine, with no device and no network. They exist because
of a real regression: `downloader.download` calls `native.set_progress(...)`, but
the app registered the method under a different name, so every progress callback
raised `AttributeError`. The hook swallows exceptions on purpose (progress is a
nicety and must never break a download), so the failure was silent and the UI
simply never moved.

Run with: python3 -m pytest tests/ -q   (or: python3 tests/test_downloader.py)
"""
import json
import os
import sys
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "app"))


class RecordingNative:
    """Stands in for the `mvnative` module the app injects into Python."""

    def __init__(self):
        self.progress = []
        self.cancelled_tasks = set()

    def cancelled(self, task):
        return task in self.cancelled_tasks

    def set_progress(self, task, payload):
        self.progress.append(json.loads(payload))


class BrokenNative:
    """Every call fails, which is what a name mismatch looks like from Python."""

    def cancelled(self, task):
        raise RuntimeError("no such method")

    def set_progress(self, task, payload):
        raise RuntimeError("no such method")


def install_fake_native(native):
    module = types.ModuleType("mvnative")
    module.cancelled = native.cancelled
    module.set_progress = native.set_progress
    sys.modules["mvnative"] = module
    return module


class ProgressHookTests(unittest.TestCase):
    def setUp(self):
        self.native = RecordingNative()
        self.module = install_fake_native(self.native)
        import downloader
        self.downloader = downloader
        self.hook = downloader._progress_hook(self.module, "task-1")

    def test_reports_fraction_speed_eta_and_title(self):
        self.hook({
            "status": "downloading",
            "downloaded_bytes": 500,
            "total_bytes": 1000,
            "speed": 1234.0,
            "eta": 7,
            "info_dict": {"title": "A video"},
        })
        self.assertEqual(len(self.native.progress), 1)
        report = self.native.progress[0]
        self.assertAlmostEqual(report["progress"], 0.5)
        self.assertEqual(report["speed"], 1234.0)
        self.assertEqual(report["eta"], 7)
        self.assertEqual(report["title"], "A video")
        self.assertEqual(report["total"], 1000)

    def test_falls_back_to_the_estimated_total(self):
        # yt-dlp often knows only an estimate while the download is running.
        self.hook({"status": "downloading", "downloaded_bytes": 250, "total_bytes_estimate": 1000})
        self.assertAlmostEqual(self.native.progress[0]["progress"], 0.25)

    def test_unknown_total_does_not_divide_by_zero(self):
        self.hook({"status": "downloading", "downloaded_bytes": 5})
        self.assertEqual(self.native.progress[0]["progress"], -1)

    def test_a_failing_native_never_breaks_the_download(self):
        # The regression above: the hook must survive a broken native silently.
        hook = self.downloader._progress_hook(BrokenNative(), "task-1")
        hook({"status": "downloading", "downloaded_bytes": 1, "total_bytes": 2})

    def test_cancellation_is_raised_out_of_the_hook(self):
        self.native.cancelled_tasks.add("task-1")
        with self.assertRaises(self.downloader._Cancelled):
            self.hook({"status": "downloading"})

    def test_cancelled_reports_false_without_a_native(self):
        self.assertFalse(self.downloader._is_cancelled(None, "task-1"))


class FormatSelectorTests(unittest.TestCase):
    """iOS ships no ffmpeg, so no selector may ask yt-dlp to merge two streams."""

    def setUp(self):
        import downloader
        self.downloader = downloader

    def test_no_selector_requires_merging(self):
        for name, selector in self.downloader.FORMATS.items():
            with self.subTest(quality=name):
                self.assertNotIn("bestvideo", selector)
                self.assertNotIn("+", selector)
                self.assertIn("/", selector)

    def test_audio_prefers_a_container_that_needs_no_conversion(self):
        self.assertTrue(self.downloader.FORMATS["audio"].startswith("bestaudio[ext=m4a]"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
