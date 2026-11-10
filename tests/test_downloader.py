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


class DownloadPanelTests(unittest.TestCase):
    """The panel offers the heights a video really has, so any number is valid."""

    def setUp(self):
        import downloader
        self.downloader = downloader

    def test_accepts_a_real_height(self):
        fmt = self.downloader._selector("1080")
        self.assertIn("height<=1080", fmt)
        self.assertIn("best[ext=mp4]", fmt)

    def test_falls_back_for_unknown_quality(self):
        best = self.downloader.FORMATS["best"]
        for bad in ["nonsense", "", "0", None, "-5"]:
            with self.subTest(quality=bad):
                self.assertEqual(self.downloader._selector(bad), best)

    def test_keeps_the_named_presets(self):
        self.assertEqual(self.downloader._selector("audio"), self.downloader.FORMATS["audio"])
        self.assertEqual(self.downloader._selector("720p"), self.downloader.FORMATS["720p"])

    def test_never_asks_for_a_merge(self):
        for quality in ["best", "720p", "480p", "audio", "1080", "2160"]:
            with self.subTest(quality=quality):
                self.assertNotIn("+", self.downloader._selector(quality))


class FailureDescriptionTests(unittest.TestCase):
    """The row must name the real reason, not 'file could not be found'.

    A feed/search page extracts to a playlist with no entries, and a DASH-only
    video has no combined format. Both used to surface as the same misleading
    message, which hid the actual cause from the log.
    """

    def setUp(self):
        import downloader
        self.downloader = downloader

    def test_an_empty_playlist_is_named_as_a_non_video_page(self):
        info = {"_type": "playlist", "id": "recommended", "entries": []}
        reason = self.downloader._describe_failure("https://m.youtube.com/?ra=m", info)
        self.assertIn("not a video", reason)

    def test_a_dash_only_video_is_named(self):
        info = {"formats": [{"format_id": "137"}, {"format_id": "140"}]}
        reason = self.downloader._describe_failure("https://m.youtube.com/watch?v=x", info)
        self.assertIn("single playable format", reason)

    def test_an_unexplained_result_still_has_a_plain_fallback(self):
        reason = self.downloader._describe_failure("https://example.com/x", {})
        self.assertTrue(reason)

    def test_a_missing_info_never_raises(self):
        self.assertTrue(self.downloader._describe_failure("https://example.com/x", None))

    def test_player_clients_skip_the_bot_blocked_web_styles(self):
        flat = [c for group in self.downloader.PLAYER_CLIENTS for c in (group or [])]
        for blocked in ["tv_simply", "web_safari", "mweb", "web_embedded"]:
            self.assertNotIn(blocked, flat)


class ErrorMessageTests(unittest.TestCase):
    """The row shows one line, so yt-dlp's coloured paragraphs are tamed."""

    def setUp(self):
        import downloader
        self.downloader = downloader

    def _payload(self, message):
        return json.loads(self.downloader._error(message))

    def test_strips_colour_codes(self):
        text = self._payload("\x1b[0;31mERROR:\x1b[0m something broke")["error"]
        self.assertNotIn("\x1b", text)
        self.assertIn("something broke", text)

    def test_names_the_bot_block_in_plain_words(self):
        text = self._payload("ERROR: Sign in to confirm you're not a bot.")["error"]
        self.assertIn("blocked", text)

    def test_names_a_missing_format(self):
        text = self._payload("Requested format is not available")["error"]
        self.assertIn("single playable format", text)

    def test_passes_an_unknown_error_through(self):
        text = self._payload("some brand new failure")["error"]
        self.assertEqual(text, "some brand new failure")


class FragmentFormatTests(unittest.TestCase):
    """The merged path fetches one stream at a time; each selector must ask for
    exactly one stream and prefer containers the native mux can copy."""

    def setUp(self):
        import downloader
        self.downloader = downloader

    def test_video_prefers_a_picture_only_mp4(self):
        fmt = self.downloader._fragment_format("video", "1080")
        self.assertTrue(fmt.startswith("bestvideo[ext=mp4][height<=1080]"))

    def test_video_keeps_the_requested_height(self):
        fmt = self.downloader._fragment_format("video", "2160")
        self.assertIn("height<=2160", fmt)

    def test_video_falls_back_to_a_progressive_mp4(self):
        # A site with no separate streams still has to produce a file.
        fmt = self.downloader._fragment_format("video", "best")
        self.assertIn("/best[ext=mp4][height<=2160]", fmt)

    def test_audio_prefers_m4a_so_the_mux_can_copy_it(self):
        fmt = self.downloader._fragment_format("audio", "best")
        self.assertTrue(fmt.startswith("bestaudio[ext=m4a]"))

    def test_no_fragment_selector_asks_yt_dlp_to_merge(self):
        for kind in ["video", "audio"]:
            with self.subTest(kind=kind):
                self.assertNotIn("+", self.downloader._fragment_format(kind, "1080"))

    def test_every_branch_is_a_fallback_chain(self):
        for kind in ["video", "audio"]:
            with self.subTest(kind=kind):
                self.assertIn("/", self.downloader._fragment_format(kind, "best"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
