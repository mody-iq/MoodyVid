"""MoodyVid downloader module using yt-dlp."""
import json
import os

# iOS ships no ffmpeg, so yt-dlp cannot merge separate video and audio streams.
# Every selector must resolve to one already-muxed file, otherwise yt-dlp aborts
# with "You have requested merging of multiple formats but ffmpeg is not installed".
FORMATS = {
    "1080p": "best[height<=1080][ext=mp4]/best[height<=1080]/best[ext=mp4]/best",
    "720p": "best[height<=720][ext=mp4]/best[height<=720]/best[ext=mp4]/best",
    "audio": "bestaudio[ext=m4a]/bestaudio/best",
    "best": "best[ext=mp4]/best",
}

# The default YouTube clients only return DASH streams (separate video and audio)
# for most videos, which we cannot merge. The android client still exposes the
# pre-muxed format 18, so it has to come first.
PLAYER_CLIENTS = ["android", "ios", "web"]


def _use_bundled_certificates():
    """Point OpenSSL at the CA bundle we ship, so HTTPS works without a system store."""
    try:
        import certifi
    except Exception:
        return
    os.environ.setdefault("SSL_CERT_FILE", certifi.where())


def _error(message):
    return json.dumps({"error": str(message)}, ensure_ascii=False)


def download(url, quality="best"):
    try:
        import yt_dlp
    except Exception as e:
        return _error(f"yt-dlp not available: {e}")

    _use_bundled_certificates()

    out_dir = os.path.join(os.environ.get("TMPDIR", "/tmp"), "moodyvid")
    try:
        os.makedirs(out_dir, exist_ok=True)
    except OSError as e:
        return _error(f"cannot create the download folder: {e}")

    ydl_opts = {
        "format": FORMATS.get(quality, FORMATS["best"]),
        "outtmpl": os.path.join(out_dir, "%(title).100s [%(id)s].%(ext)s"),
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "retries": 3,
        "fragment_retries": 3,
        "extractor_args": {"youtube": {"player_client": PLAYER_CLIENTS}},
    }

    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=True)
            filename = _downloaded_path(ydl, info)
    except Exception as e:
        return _error(e)

    if not filename or not os.path.exists(filename):
        return _error("the download finished but the file could not be found")
    return json.dumps({
        "path": filename,
        "title": info.get("title", ""),
        "ext": info.get("ext", ""),
    }, ensure_ascii=False)


def _downloaded_path(ydl, info):
    """yt-dlp only fills requested_downloads once the file really exists."""
    for entry in info.get("requested_downloads") or []:
        path = entry.get("filepath")
        if path and os.path.exists(path):
            return path
    return ydl.prepare_filename(info)
