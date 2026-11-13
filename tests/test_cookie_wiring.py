"""Source-level guards for stream resources; native tests exercise the policy."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class StreamCookieContextTests(unittest.TestCase):
    def test_nested_hls_and_dash_requests_keep_the_page_or_manifest_context(self):
        # A manually entered manifest has no page Referer. Each nested URL must
        # still use the ORIGINAL manifest as its context, not the nested target,
        # or an untrusted manifest could request unrelated browser cookies.
        resources = {
            "MVHLSDownloader.m": ("variant", "job.mapSegment.url", "key.uri", "segment.url"),
            # Both DASH initialization tracks and media use segment.url in a
            # shared loop; each still inherits the original page/manifest context.
            "MVMPDDownloader.m": ("segment.url",),
        }
        for filename, targets in resources.items():
            source = (ROOT / "Sources" / filename).read_text(encoding="utf-8")
            for target in targets:
                with self.subTest(file=filename, target=target):
                    pattern = (r"\[MVMediaProbe\s+headersForURL:" + re.escape(target) +
                               r"\s+referer:job\.task\.resourceContextURL\s*\]")
                    self.assertRegex(source, pattern)
        dash = (ROOT / "Sources/MVMPDDownloader.m").read_text(encoding="utf-8")
        self.assertIn("if (job.mapSegment) [maps addObject:job.mapSegment]", dash)
        self.assertIn("if (job.audioMapSegment) [maps addObject:job.audioMapSegment]", dash)

    def test_native_sessions_and_clear_do_not_retain_shared_network_state(self):
        shared = (ROOT / "Sources/MVHTTPSession.m").read_text(encoding="utf-8")
        fast = (ROOT / "Sources/MVFastDownloader.m").read_text(encoding="utf-8")
        settings = (ROOT / "Sources/MVSettingsViewController.m").read_text(encoding="utf-8")
        for line in ("config.HTTPShouldSetCookies = NO;", "config.HTTPCookieStorage = nil;",
                     "config.URLCredentialStorage = nil;", "config.URLCache = nil;"):
            with self.subTest(line=line):
                self.assertIn(line, shared)
                self.assertEqual(fast.count(line), 2)  # probe and segment sessions
        self.assertIn("[sharedCookies deleteCookie:cookie]", settings)
        self.assertIn("[NSURLCache.sharedURLCache removeAllCachedResponses]", settings)


if __name__ == "__main__":
    unittest.main()
