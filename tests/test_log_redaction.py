"""Exercise the logger's actual ICU regexes off-device when ICU is present.

NSRegularExpression uses ICU. This tests the patterns extracted from MVLog.m,
not a second redaction implementation; native tests also cover file export.
"""
import ctypes
import ctypes.util
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_icu():
    library = ctypes.util.find_library("icui18n")
    if not library:
        return None
    try:
        lib = ctypes.CDLL(library)
        version = re.search(r"\.so\.(\d+)", library)
        suffixes = (["_" + version.group(1)] if version else []) + [""]
        for suffix in suffixes:
            try:
                getattr(lib, "uregex_open" + suffix)
                return lib, suffix
            except AttributeError:
                pass
    except OSError:
        pass
    return None


ICU = load_icu()


class ICURedactor:
    def __init__(self):
        self.lib, suffix = ICU
        try:
            self.open = getattr(self.lib, "uregex_open" + suffix)
            self.set_text = getattr(self.lib, "uregex_setText" + suffix)
            self.replace = getattr(self.lib, "uregex_replaceAll" + suffix)
            self.close = getattr(self.lib, "uregex_close" + suffix)
        except AttributeError as exc:
            raise unittest.SkipTest(f"ICU regex symbols unavailable: {exc}")
        u16ptr = ctypes.POINTER(ctypes.c_uint16)
        errorptr = ctypes.POINTER(ctypes.c_int32)
        self.open.argtypes = [u16ptr, ctypes.c_int32, ctypes.c_uint32, ctypes.c_void_p, errorptr]
        self.open.restype = ctypes.c_void_p
        self.set_text.argtypes = [ctypes.c_void_p, u16ptr, ctypes.c_int32, errorptr]
        self.replace.argtypes = [ctypes.c_void_p, u16ptr, ctypes.c_int32, u16ptr, ctypes.c_int32, errorptr]
        self.replace.restype = ctypes.c_int32
        self.close.argtypes = [ctypes.c_void_p]

        source = (ROOT / "Sources/MVLog.m").read_text(encoding="utf-8")
        expressions = source.split("NSArray<NSString *> *expressions = @[", 1)[1].split("];", 1)[0]
        literals = re.findall(r'@"((?:\\.|[^"\\])*)"', expressions)
        # These Objective-C string literals use the same escapes as JSON.
        self.patterns = [json.loads('"' + item + '"') for item in literals]
        if not self.patterns:
            raise AssertionError("no redaction expressions found")

    @staticmethod
    def chars(text):
        raw = text.encode("utf-16-le")
        return (ctypes.c_uint16 * (len(raw) // 2)).from_buffer_copy(raw)

    def apply(self, pattern, text):
        p = self.chars(pattern)
        status = ctypes.c_int32(0)
        regex = self.open(p, len(p), 0, None, ctypes.byref(status))
        if status.value > 0 or not regex:
            raise AssertionError(f"ICU could not compile {pattern!r}: {status.value}")
        try:
            value = self.chars(text)
            self.set_text(regex, value, len(value), ctypes.byref(status))
            replacement = self.chars("[redacted]")
            output = (ctypes.c_uint16 * (len(value) * 4 + 128))()
            length = self.replace(regex, replacement, len(replacement), output, len(output), ctypes.byref(status))
            if status.value > 0:
                raise AssertionError(f"ICU replacement failed: {status.value}")
            return bytes(output)[:length * 2].decode("utf-16-le")
        finally:
            self.close(regex)

    def redact(self, text):
        for pattern in self.patterns:
            text = self.apply(pattern, text)
        return text


@unittest.skipUnless(ICU, "ICU regex library unavailable; macOS native tests cover this")
class LogRedactionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.redactor = ICURedactor()

    def test_sensitive_strings_are_hidden_and_redaction_is_idempotent(self):
        cases = [
            ("open https://alice:pass@example.test/private?token=urlSecret#frag", ["alice", "pass", "example.test", "urlSecret"]),
            ("magnet:?xt=urn:btih:myHash&tr=https%3A%2F%2Ftracker.test", ["myHash", "tracker.test"]),
            ("magnet%3A%3Fxt=urn%3Abtih%3AmyHash", ["myHash"]),
            ("url=https%3A%2F%2Fexample.test%2Fprivate", ["example.test", "private"]),
            ("url=https%3A//example.test/private", ["example.test", "private"]),
            ("url=https:%2F/example.test/private", ["example.test", "private"]),
            (r"url=https:\/\/example.test\/private", ["example.test", "private"]),
            ("Cookie: a=cookieSecret; b=secondSecret", ["cookieSecret", "secondSecret"]),
            ('"Authorization": "Bearer headerSecret"', ["headerSecret"]),
            ("Set-Cookie: secretCookie=abc; Path=/", ["secretCookie", "abc"]),
            ("access_token=tokenSecret password=otherSecret", ["tokenSecret", "otherSecret"]),
            ('api_key: "apiSecret"', ["apiSecret"]),
            ("Bearer bearerSecret", ["bearerSecret"]),
        ]
        for text, secrets in cases:
            with self.subTest(text=text):
                clean = self.redactor.redact(text)
                self.assertIn("[redacted]", clean)
                for secret in secrets:
                    self.assertNotIn(secret, clean)
                self.assertEqual(clean, self.redactor.redact(clean))

    def test_ordinary_diagnostics_are_preserved(self):
        text = "download failed: HTTP 403"
        self.assertEqual(self.redactor.redact(text), text)


class LogIntegrationGuardTests(unittest.TestCase):
    def test_both_log_sinks_receive_redacted_messages(self):
        source = (ROOT / "Sources/MVLog.m").read_text(encoding="utf-8")
        method = source.split('+ (void)log:', 1)[1].split('- (BOOL)redactExistingLogs', 1)[0]
        self.assertLess(method.index("[self redactedText:message]"), method.index("NSLog("))
        self.assertLess(method.index("[self redactedText:message]"), method.index("[log appendLine:line]"))

    def test_share_sheet_uses_only_prepared_copies(self):
        settings = (ROOT / "Sources/MVSettingsViewController.m").read_text(encoding="utf-8")
        self.assertIn("[MVLog prepareRedactedLogsWithCompletion:", settings)
        self.assertNotIn("[MVLog logFileURLs]", settings)
        self.assertIn("redacted where recognized", settings)
        self.assertIn("may still contain sensitive information", settings)


if __name__ == "__main__":
    unittest.main()
