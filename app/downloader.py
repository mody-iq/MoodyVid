"""MoodyVid downloader module using yt-dlp."""
import hashlib
import json
import os
import re
import stat
import time
from urllib.parse import urlsplit

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


_FORMAT_ID = re.compile(r"^[A-Za-z0-9._-]{1,80}$", re.ASCII)


def _explicit_format(quality, prefix):
    """Accept one extractor-supplied ID, never an arbitrary yt-dlp expression."""
    if not isinstance(quality, str) or not quality.startswith(prefix):
        return None
    value = quality[len(prefix):]
    return value if _FORMAT_ID.fullmatch(value) else None


def _selector(quality):
    """The yt-dlp format string for a quality the UI asked for.

    The download panel offers the real heights a video has, so the request can be
    any number of pixels ("1080"), not just the named presets. Every branch still
    resolves to one combined file: there is no ffmpeg on iOS to merge two.
    """
    explicit = _explicit_format(quality, "fmt:")
    if explicit:
        return explicit
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
    """The Files-app folder where native code publishes finished downloads."""
    base = (os.environ.get("MV_DOCUMENTS")
            or os.environ.get("HOME")
            or os.environ.get("TMPDIR", "/tmp"))
    return os.path.join(base, "MoodyVid")


def _task_output_dir(task):
    """A stable, private workspace for one native record, shared across retries.

    Extractors can resolve different URLs to the same title and video ID; a
    directory per record prevents both final names and yt-dlp's .part files from
    colliding. Hash the identifier rather than using it as a path component. The
    native side uses the same SHA-256 convention when publishing and deleting.
    Calls without a native task retain the standalone API's original location.
    """
    if not task:
        return _output_dir()
    owner = hashlib.sha256(task.encode("utf-8")).hexdigest()
    return os.path.join(_output_dir(), ".moodyvid-work", owner)


def _prepare_output_dir(task):
    """Create an isolated workspace without following a redirected work root.

    yt-dlp writes ordinary pathnames, so a concurrently replaced directory cannot
    be fully protected here; native publication checks ownership again. Existing
    symlinks are rejected before the downloader writes into them.
    """
    output = _output_dir()
    os.makedirs(output, exist_ok=True)
    if not task:
        return output
    root = os.path.join(output, ".moodyvid-work")
    work = _task_output_dir(task)
    for directory in (root, work):
        try:
            os.mkdir(directory)
        except FileExistsError:
            pass
        if not stat.S_ISDIR(os.lstat(directory).st_mode):
            raise OSError("download workspace is not a safe directory")
    return work


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


_PREVIEW_LIMIT = 100


def _safe_http_url(value):
    """A playlist result is untrusted input: never queue local or custom URLs."""
    if not isinstance(value, str) or not value or len(value) > 8192:
        return None
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        return None
    try:
        parsed = urlsplit(value)
        if parsed.scheme.lower() not in ("http", "https") or not parsed.hostname:
            return None
        _ = parsed.port  # reject malformed and out-of-range ports
    except ValueError:
        return None
    return value


def _preview_info(url, playlist):
    """Extract metadata without downloading; bound playlist size and retries."""
    if not _safe_http_url(url):
        raise ValueError("enter an HTTP or HTTPS link")
    import yt_dlp
    _use_bundled_certificates()
    last_error = None
    for client in _client_order():
        opts = {"quiet": True, "no_warnings": True, "skip_download": True,
                "noplaylist": not playlist, "socket_timeout": 8, "retries": 1}
        if playlist:
            opts.update({"extract_flat": "in_playlist", "playlistend": _PREVIEW_LIMIT + 1,
                         "ignoreerrors": True, "lazy_playlist": True})
        if client:
            opts["extractor_args"] = {"youtube": {"player_client": client}}
        try:
            with yt_dlp.YoutubeDL(opts) as ydl:
                info = ydl.extract_info(url, download=False)
                # Flat playlists can be lazy generators that require the still
                # open YoutubeDL context; consume at most one beyond the limit.
                if playlist and isinstance(info, dict) and info.get("entries") is not None:
                    entries = []
                    for entry in info["entries"]:
                        entries.append(entry)
                        if len(entries) > _PREVIEW_LIMIT:
                            break
                    info = dict(info, entries=entries)
            if isinstance(info, dict):
                _good_client[0], _good_client[1] = client, time.time()
                return info
            last_error = ValueError("the link did not return media details")
        except Exception as exc:
            last_error = exc
    raise last_error or ValueError("could not read the link")


def _number(value, maximum):
    # bool is a subclass of int; NaN and infinite values must not reach JSON/UI.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    if not (0 < value <= maximum):
        return 0
    return int(value)


def _format_choices(info):
    """Return actual MP4 video formats the app can try to play or mux.

    Each choice carries a single, validated format ID, not a selector expression.
    For separate video streams the reported size explicitly excludes audio.
    """
    formats = info.get("formats")
    if not isinstance(formats, list):
        formats = [info]
    has_audio = any(isinstance(f, dict) and f.get("acodec") not in (None, "none")
                    and f.get("vcodec") in (None, "none") for f in formats)
    selected = {}
    for f in formats[:2000]:
        if not isinstance(f, dict):
            continue
        format_id = f.get("format_id")
        height = _number(f.get("height"), 8640)
        if not isinstance(format_id, str) or not _FORMAT_ID.fullmatch(format_id) or not height:
            continue
        if str(f.get("ext", "")).lower() not in ("mp4", "m4v", "mov"):
            continue
        codec = str(f.get("vcodec") or "").lower()
        if not codec.startswith(("avc", "h264", "hev", "hvc", "h265")):
            continue
        separate = f.get("acodec") in (None, "none")
        if separate and not has_audio:
            continue
        fps = _number(f.get("fps"), 240)
        size = _number(f.get("filesize"), 1 << 50)
        estimated = False
        if not size:
            size = _number(f.get("filesize_approx"), 1 << 50)
            estimated = bool(size)
        rate = _number(f.get("tbr"), 10000000)
        choice = {"quality": ("split:" if separate else "fmt:") + format_id,
                  "height": height, "fps": fps, "ext": str(f.get("ext")).lower(),
                  "size": size, "estimated": estimated, "video_only": separate}
        # One actual variant per height keeps the sheet short. Prefer higher fps,
        # then a combined file, then bitrate; do not fabricate an exact total size.
        score = (fps, not separate, rate)
        if height not in selected or score > selected[height][0]:
            selected[height] = (score, choice)
    return [selected[h][1] for h in sorted(selected, reverse=True)[:20]]


def inspect_formats(url):
    """UI preview: actual usable video formats, with best-effort sizes."""
    try:
        info = _preview_info(url, False)
        return json.dumps({"formats": _format_choices(info)}, ensure_ascii=False)
    except Exception as exc:
        return _error(exc)


def _playlist_entry_url(entry):
    for key in ("webpage_url", "original_url", "url"):
        value = _safe_http_url(entry.get(key))
        if value:
            return value
    # yt-dlp's flat YouTube extractor often supplies a bare ID rather than URL.
    video_id = entry.get("id") or entry.get("url")
    if (str(entry.get("ie_key") or "").lower() == "youtube" and
            isinstance(video_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id)):
        return "https://www.youtube.com/watch?v=" + video_id
    return None


def inspect_playlist(url):
    """Return at most 100 selectable video URLs; never queue anything here."""
    try:
        info = _preview_info(url, True)
        entries = info.get("entries")
        if not isinstance(entries, list):
            return _error("this link is not a supported playlist")
        rows = []
        seen = set()
        for entry in entries[:_PREVIEW_LIMIT]:
            if not isinstance(entry, dict) or entry.get("_type") in ("playlist", "multi_video"):
                continue
            address = _playlist_entry_url(entry)
            if not address or address in seen:
                continue
            seen.add(address)
            title = entry.get("title")
            title = title[:300] if isinstance(title, str) and title.strip() else address
            rows.append({"url": address, "title": title,
                         "duration": _number(entry.get("duration"), 7 * 24 * 60 * 60)})
        if not rows:
            return _error("no selectable videos were found in this playlist")
        title = info.get("title")
        return json.dumps({"title": title[:300] if isinstance(title, str) else "",
                           "entries": rows, "truncated": len(entries) > _PREVIEW_LIMIT},
                          ensure_ascii=False)
    except Exception as exc:
        return _error(exc)


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

    try:
        out_dir = _prepare_output_dir(_task)
    except OSError as e:
        return _error(f"cannot create the download folder: {e}")

    fmt = _selector(quality)
    native = _native()
    last_error = None
    for client in _client_order():
        if _is_cancelled(native, _task):
            return _error("cancelled")
        if _is_paused(native, _task):
            return _error("paused")
        try:
            info, filename = _download_once(yt_dlp, url, fmt, client, out_dir, native, _task)
        except _Cancelled:
            return _error("cancelled")
        except _Paused:
            return _error("paused")
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


class _Paused(Exception):
    """Raised from the progress hook when the UI asked the task to pause.

    yt-dlp cannot be suspended in place, so pausing unwinds the download the
    same way a cancel does — but the caller keeps the .part file and reports
    "paused" instead of "cancelled", so a resume continues where it stopped.
    """


def _is_cancelled(native, task):
    if not native or not task:
        return False
    try:
        return bool(native.cancelled(task))
    except BaseException:
        return False


def _is_paused(native, task):
    """True while the UI wants this task held. Pausing is distinct from
    cancelling: the .part file stays on disk so the download can continue."""
    if not native or not task:
        return False
    try:
        return bool(native.paused(task))
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
        # A pause also unwinds the yt-dlp call (there is no way to suspend it in
        # place); the caller treats it as "keep the .part file" instead of a
        # failure, and the download continues from that file on resume.
        if _is_paused(native, task):
            raise _Paused()
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
        "outtmpl": os.path.join(out_dir, "%(title).100B [%(id).64B].%(ext)s"),
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
    explicit = _explicit_format(quality, "split:")
    if explicit:
        return explicit
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
    if kind not in ("video", "audio"):
        return _error("invalid stream kind")
    try:
        import yt_dlp
    except Exception as e:
        return _error(f"yt-dlp not available: {e}")

    _use_bundled_certificates()

    fmt = _fragment_format(kind, quality)

    try:
        out_dir = _prepare_output_dir(_task)
    except OSError as e:
        return _error(f"cannot create the download folder: {e}")

    native = _native()
    for client in _client_order():
        if _is_cancelled(native, _task):
            return _error("cancelled")
        if _is_paused(native, _task):
            return _error("paused")
        try:
            opts = {
                "format": fmt,
                # A marker per stream: the video and the audio are separate runs,
                # and a site with no audio-only format can make both resolve to
                # the same extension. The marker keeps the two files apart so one
                # can never overwrite the other.
                "outtmpl": os.path.join(out_dir,
                                        "%(title).100B [%(id).64B]." + kind + ".%(ext)s"),
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
        except _Paused:
            return _error("paused")
        except Exception as e:
            continue
    return _error("the stream could not be downloaded")


def _has_video(info):
    return any(f.get("vcodec") not in (None, "none")
               for f in info.get("requested_formats") or [info])

