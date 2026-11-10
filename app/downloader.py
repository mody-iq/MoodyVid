"""MoodyVid downloader module using yt-dlp."""
import json
import os
import re
import time

# iOS ships no ffmpeg, so yt-dlp cannot merge a separate video stream with a
# separate audio stream. Every selector must therefore resolve to one file that
# already carries both, otherwise the download aborts with
# "You have requested merging of multiple formats but ffmpeg is not installed".
# A bare `best` is safe: it only ever matches a combined format, never video-only.
FORMATS = {
    "best": "best[ext=mp4]/best",
    "720p": "best[height<=720][ext=mp4]/best[height<=720]/best[ext=mp4]/best",
    "480p": "best[height<=480][ext=mp4]/best[height<=480]/best[ext=mp4]/best",
    "audio": "bestaudio[ext=m4a]/bestaudio/best[ext=mp4]/best",
}


def _selector(quality):
    """The yt-dlp format string for a quality the UI asked for.

    The download panel offers the real heights a video has, so the request can be
    any number of pixels ("1080"), not just the named presets. Every branch still
    resolves to one combined file: there is no ffmpeg on iOS to merge two.
    """
    if quality in FORMATS:
        return FORMATS[quality]
    if isinstance(quality, str) and quality.isdigit():
        height = int(quality)
        if height > 0:
            return (f"best[height<={height}][ext=mp4]/best[height<={height}]"
                    f"/best[ext=mp4]/best")
    return FORMATS["best"]

# YouTube blocks a connection style without warning, and the default clients now
# hand out DASH-only streams (video and sound apart) for most videos. Try the
# styles that still expose a combined file, in order, and remember the one that
# worked so the next video starts there instead of repeating the failures.
# "android" cracks the combined mp4 in one fast round on real traffic. The web
# clients (tv_simply, web_safari, mweb) are gone: YouTube answers them with
# "Sign in to confirm you're not a bot", so they only cost a round trip.
PLAYER_CLIENTS = [["android"], ["ios"], ["visionos"], None]
_good_client = [None, 0.0]
_GOOD_CLIENT_TTL = 3600


def _register_javascriptcore():
    """Teach yt-dlp to run its YouTube player challenges in JavaScriptCore.

    YouTube signs its streams with a script that yt-dlp has to execute. On a
    desktop that means node or deno, which iOS cannot ship; Apple's JavaScriptCore
    is already in the OS, so we register it as a runtime and as the solver
    provider that uses it. Without this, downloads fall back to whatever the
    plain player client offers, which is usually a low resolution.

    Best-effort: if yt-dlp's internals differ, the app still downloads normally.
    """
    try:
        import mvnative
    except BaseException:
        return False
    try:
        from yt_dlp.globals import supported_js_runtimes
        from yt_dlp.utils._jsruntime import JsRuntime, JsRuntimeInfo

        class _JavaScriptCoreRuntime(JsRuntime):
            def _info(self):
                return JsRuntimeInfo(name='javascriptcore', path='builtin',
                                     version='1', version_tuple=(1,), supported=True)

        supported_js_runtimes.value['javascriptcore'] = _JavaScriptCoreRuntime

        from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
        from yt_dlp.extractor.youtube.jsc.provider import (
            JsChallengeProviderError, register_preference, register_provider)
        from yt_dlp.extractor.youtube.pot._provider import BuiltinIEContentProvider

        @register_provider
        class JavaScriptCoreJCP(EJSBaseJCP, BuiltinIEContentProvider):
            PROVIDER_NAME = 'javascriptcore'
            JS_RUNTIME_NAME = 'javascriptcore'

            def is_available(self, /):
                return True

            def _run_js_runtime(self, stdin, /):
                ok, out = mvnative.run_js(stdin)
                if not ok:
                    raise JsChallengeProviderError(f'JavaScriptCore error: {out}')
                return out

        @register_preference(JavaScriptCoreJCP)
        def _preference(provider, requests):
            return 1000

        return True
    except BaseException:
        return False


_HAS_JAVASCRIPTCORE = _register_javascriptcore()


def _use_bundled_certificates():
    """Point OpenSSL at the CA bundle we ship, so HTTPS works without a system store."""
    try:
        import certifi
    except Exception:
        return
    os.environ.setdefault("SSL_CERT_FILE", certifi.where())


def _output_dir():
    """The Files-app folder we ship downloads into, so they survive and are visible."""
    base = (os.environ.get("MV_DOCUMENTS")
            or os.environ.get("HOME")
            or os.environ.get("TMPDIR", "/tmp"))
    return os.path.join(base, "MoodyVid")


_ANSI = re.compile(r"\x1b\[[0-9;]*m")

# yt-dlp's messages are long and coloured; the row shows one short line, so the
# frequent ones get a plain wording. Anything else is passed through, stripped.
_FRIENDLY = (
    ("not a bot", "YouTube blocked this request; please try again in a moment"),
    ("Requested format is not available",
     "this video has no single playable format; try a lower quality"),
    ("HTTP Error 403", "the server refused the download (403)"),
    ("Video unavailable", "this video is not available"),
    ("Private video", "this video is private"),
)


def _error(message):
    text = _ANSI.sub("", str(message))
    for needle, friendly in _FRIENDLY:
        if needle in text:
            text = friendly
            break
    return json.dumps({"error": text}, ensure_ascii=False)


def _describe_failure(url, info):
    """A plain reason a finished run produced no file.

    The generic "the file could not be found" hid the real causes: a page that
    is not a video (a feed, a search page) extracts to a playlist with no items,
    and a DASH-only video has no single combined format to fetch. Both are worth
    naming so the row can say what actually happened.
    """
    if isinstance(info, dict):
        if info.get("_type") == "playlist" or info.get("entries") is not None:
            count = len(info.get("entries") or [])
            if count == 0:
                return "this link is not a video — it is a page with no media on it"
        if info.get("formats") and not info.get("url") and not info.get("requested_downloads"):
            return "this video has no single playable format; try a lower quality"
    return "the download finished but no file was produced"


def _native():
    """The native helpers, or None off-device (tests import this module directly)."""
    try:
        import mvnative
        return mvnative
    except BaseException:
        return None


def _client_order():
    """The remembered client first, then the rest, skipping a duplicate."""
    order = list(PLAYER_CLIENTS)
    good, when = _good_client
    if good is not None and time.time() - when < _GOOD_CLIENT_TTL and good in order[1:]:
        order.remove(good)
        order.insert(0, good)
    return order




def prewarm():
    """Imports the heavy modules once, at launch, so the first download does not
    have to pay the import cost while the spinner is on screen.

    Must be callable off-device for the tests, which import this file directly.
    Returns a small dict so the native side can log what warmed up.
    """
    warmed = []
    try:
        import yt_dlp  # noqa: F401
        warmed.append("yt_dlp")
    except BaseException:
        pass
    _use_bundled_certificates()
    _native()
    try:
        # Instantiate once so the extractor's lazy class registry populates and
        # the JS challenges warm their caches.
        with yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True}) as ydl:
            _ = ydl  # noqa
        warmed.append("YoutubeDL")
    except BaseException:
        pass
    return json.dumps({"warmed": warmed}, ensure_ascii=False)


def download(url, quality="best", _task=""):
    try:
        import yt_dlp
    except Exception as e:
        return _error(f"yt-dlp not available: {e}")

    _use_bundled_certificates()

    out_dir = _output_dir()
    try:
        os.makedirs(out_dir, exist_ok=True)
    except OSError as e:
        return _error(f"cannot create the download folder: {e}")

    fmt = _selector(quality)
    native = _native()
    last_error = None
    for client in _client_order():
        if _is_cancelled(native, _task):
            return _error("cancelled")
        try:
            info, filename = _download_once(yt_dlp, url, fmt, client, out_dir, native, _task)
        except _Cancelled:
            return _error("cancelled")
        except Exception as e:
            last_error = e
            continue
        if filename:
            _good_client[0], _good_client[1] = client, time.time()
            return json.dumps({
                "path": filename,
                "title": info.get("title", ""),
                "thumbnail": info.get("thumbnail", ""),
                "ext": info.get("ext", ""),
                "height": info.get("height") or 0,
                "audio": quality == "audio" and not _has_video(info),
            }, ensure_ascii=False)
        # No file: this URL is not a video, or it offers no combined format. Both
        # are permanent, so stop rather than asking the next client the same
        # question. Only a real exception (a blocked client) is worth retrying.
        return _error(_describe_failure(url, info))

    return _error(last_error or "download failed")


class _Cancelled(Exception):
    """Raised from the progress hook when the UI asked the task to stop."""


def _is_cancelled(native, task):
    if not native or not task:
        return False
    try:
        return bool(native.cancelled(task))
    except BaseException:
        return False


def _progress_hook(native, task):
    """Feeds live progress back to the UI, and stops the download on request.

    The UI cannot be called from here (this runs on a worker thread inside
    Python), so we hand the numbers to the native side and let it poll. Raising
    from the hook is the documented way to abort a yt-dlp download.
    """
    def hook(status):
        if _is_cancelled(native, task):
            raise _Cancelled()
        if not native or not task:
            return
        try:
            state = status.get("status")
            total = status.get("total_bytes") or status.get("total_bytes_estimate") or 0
            downloaded = status.get("downloaded_bytes") or 0
            progress = (downloaded / total) if total else -1
            native.set_progress(task, json.dumps({
                "status": state or "",
                "progress": progress,
                "speed": status.get("speed") or 0,
                "eta": status.get("eta") or 0,
                "total": total,
                "title": status.get("info_dict", {}).get("title", ""),
            }))
        except BaseException:
            # Progress is a nicety; never let it break the download.
            pass
    return hook


def _download_once(yt_dlp, url, fmt, client, out_dir, native=None, task=""):
    opts = {
        "format": fmt,
        "outtmpl": os.path.join(out_dir, "%(title).100B [%(id)s].%(ext)s"),
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "retries": 10,
        "fragment_retries": 10,
        # Resume the tail of an interrupted download instead of restarting it.
        "continue": True,
        # A blocked style should fail quickly so the next one is tried.
        "socket_timeout": 8,
        "progress_hooks": [_progress_hook(native, task)],
    }
    if client:
        opts["extractor_args"] = {"youtube": {"player_client": client}}
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=True)
        return info, _downloaded_path(ydl, info)


def _downloaded_path(ydl, info):
    """yt-dlp only fills requested_downloads once the file really exists."""
    for entry in info.get("requested_downloads") or []:
        path = entry.get("filepath")
        if path and os.path.exists(path):
            return path
    path = ydl.prepare_filename(info)
    return path if path and os.path.exists(path) else None


def _fragment_format(kind, quality):
    """The yt-dlp selector for ONE stream of a merged download.

    iOS has no ffmpeg, so the app fetches the picture and the sound separately
    and muxes them itself. The video branch prefers a picture-only MP4 (the mux
    adds the sound, so a combined file would only waste bandwidth), and falls
    back to a progressive MP4 for a site that has no separate streams. The audio
    branch prefers M4A so the mux can copy the track without re-encoding.
    """
    if kind == "audio":
        return "bestaudio[ext=m4a]/bestaudio[ext=mp4]/bestaudio/best[ext=m4a]/best"
    height = 2160
    if isinstance(quality, str):
        digits = quality[:-1] if quality.endswith("p") else quality
        if digits.isdigit():
            h = int(digits)
            if h > 0:
                height = h
    return (f"bestvideo[ext=mp4][height<={height}]"
            f"/bestvideo[height<={height}]"
            f"/best[ext=mp4][height<={height}]"
            f"/best[height<={height}]")


def download_fragment(url, kind, quality="best", _task=""):
    """Downloads ONE stream (kind="video" or "audio") to a single file.

    iOS has no ffmpeg, so higher qualities cannot be merged inside yt-dlp. The
    app instead downloads the video stream and the audio stream separately
    (progressive) and muxes them natively with AVFoundation. This function
    returns just the one fragment; the native side combines the pair.
    """
    try:
        import yt_dlp
    except Exception as e:
        return _error(f"yt-dlp not available: {e}")

    _use_bundled_certificates()

    fmt = _fragment_format(kind, quality)

    out_dir = _output_dir()
    try:
        os.makedirs(out_dir, exist_ok=True)
    except OSError as e:
        return _error(f"cannot create the download folder: {e}")

    native = _native()
    for client in _client_order():
        if _is_cancelled(native, _task):
            return _error("cancelled")
        try:
            opts = {
                "format": fmt,
                # A marker per stream: the video and the audio are separate runs,
                # and a site with no audio-only format can make both resolve to
                # the same extension. The marker keeps the two files apart so one
                # can never overwrite the other.
                "outtmpl": os.path.join(out_dir,
                                        "%(title).100B [%(id)s]." + kind + ".%(ext)s"),
                "quiet": True,
                "no_warnings": True,
                "noplaylist": True,
                "retries": 10,
                "fragment_retries": 10,
                "continue": True,
                "socket_timeout": 8,
                "progress_hooks": [_progress_hook(native, _task)],
            }
            if client:
                opts["extractor_args"] = {"youtube": {"player_client": client}}
            with yt_dlp.YoutubeDL(opts) as ydl:
                info = ydl.extract_info(url, download=True)
                path = _downloaded_path(ydl, info)
            if path:
                _good_client[0], _good_client[1] = client, time.time()
                return json.dumps({
                    "path": path,
                    "title": info.get("title", ""),
                    "thumbnail": info.get("thumbnail", ""),
                    "ext": path.lower().rsplit(".", 1)[-1] if "." in path else "",
                }, ensure_ascii=False)
        except _Cancelled:
            return _error("cancelled")
        except Exception as e:
            continue
    return _error("the stream could not be downloaded")


def _has_video(info):
    return any(f.get("vcodec") not in (None, "none")
               for f in info.get("requested_formats") or [info])

