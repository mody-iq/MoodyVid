"""MoodyVid downloader module using yt-dlp."""
import json
import os
import sys


def download(url, quality="best"):
    try:
        import yt_dlp
    except Exception as e:
        return json.dumps({"error": f"yt-dlp not available: {e}"})
    try:
        out_dir = os.path.join(os.environ.get("TMPDIR", "/tmp"), "moodyvid")
        os.makedirs(out_dir, exist_ok=True)
        ydl_opts = {
            "format": quality if quality and quality != "best" else "best",
            "outtmpl": os.path.join(out_dir, "%(title)s.%(ext)s"),
            "quiet": True,
            "no_warnings": True,
        }
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=True)
            filename = ydl.prepare_filename(info)
        return json.dumps({"path": filename, "title": info.get("title", "")})
    except Exception as e:
        return json.dumps({"error": str(e)})
