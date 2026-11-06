"""MoodyVid downloader module using yt-dlp."""
import json
import os
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

# YouTube blocks a connection style without warning, and the default clients now
# hand out DASH-only streams (video and sound apart) for most videos. Try the
# styles that still expose a combined file, in order, and remember the one that
# worked so the next video starts there instead of repeating the failures.
PLAYER_CLIENTS = [None, ["visionos", "web_embedded", "mweb"], ["android"], ["tv_simply", "web_safari"]]
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


def _error(message):
    return json.dumps({"error": str(message)}, ensure_ascii=False)


def _client_order():
    """The remembered client first, then the rest, skipping a duplicate."""
    order = list(PLAYER_CLIENTS)
    good, when = _good_client
    if good is not None and time.time() - when < _GOOD_CLIENT_TTL and good in order[1:]:
        order.remove(good)
        order.insert(0, good)
    return order


def download(url, quality="best"):
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

    fmt = FORMATS.get(quality, FORMATS["best"])
    last_error = None
    for client in _client_order():
        try:
            info, filename = _download_once(yt_dlp, url, fmt, client, out_dir)
        except Exception as e:
            last_error = e
            continue
        if filename:
            _good_client[0], _good_client[1] = client, time.time()
            return json.dumps({
                "path": filename,
                "title": info.get("title", ""),
                "ext": info.get("ext", ""),
                "height": info.get("height") or 0,
                "audio": quality == "audio" and not _has_video(info),
            }, ensure_ascii=False)
        last_error = last_error or "the download finished but the file could not be found"

    return _error(last_error or "download failed")


def _download_once(yt_dlp, url, fmt, client, out_dir):
    opts = {
        "format": fmt,
        "outtmpl": os.path.join(out_dir, "%(title).100B [%(id)s].%(ext)s"),
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "retries": 3,
        "fragment_retries": 3,
        # A blocked style should fail quickly so the next one is tried.
        "socket_timeout": 15,
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


def _has_video(info):
    return any(f.get("vcodec") not in (None, "none")
               for f in info.get("requested_formats") or [info])

