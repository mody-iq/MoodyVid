# VidGrab study (github.com/iamjhe08/VidGrab) — 2026-11-06

Reference app the user wants MoodyVid to resemble. Cloned to /tmp/vidgrab.

## What it is
- iOS video downloader, **GPL-3.0**, iOS 15+, 159 stars, ~210 files, 48 .m + 47 .h.
- Built with **Theos** (Makefile, `TARGET := iphone:clang:16.5:15.0`), not GitHub Actions.
  assemble.py uses Linux paths (`/root/pyios`, `/root/theos`, `/root/ffmpeg-ios`).
- Ships an unsigned IPA + TrollStore .tipa + a sideload repo (Feather/AltStore).

## The four mechanisms that matter (vs MoodyVid)
1. **JavaScriptCore as a yt-dlp JS provider.** `app/vgbridge.py::_register_jsc()` subclasses
   `EJSBaseJCP` + `BuiltinIEContentProvider`, `PROVIDER_NAME='javascriptcore'`, and calls
   `vgnative.run_js()`. Fixes the "no supported JavaScript runtime" weakness in MoodyVid.
2. **Native progress + cancel.** C extension module `vgnative` (in `Sources/VGPython.m`) exposes
   `progress(task,part,parts,frac,stage,speed,eta)`, `cancelled(task)`, `can_convert()`, `run_js(code)`.
   Python's `progress_hooks` call `vgnative.progress`; the hook raises `DownloadCancelled` when
   `vgnative.cancelled(task)`. ObjC side dispatches to the main queue via a per-task handler.
3. **ffmpeg static libs built for iOS arm64** (`tools/build_ffmpeg_ios.sh`) with
   `--disable-everything` + a hand-picked decoder/encoder/muxer list. Enables real merging
   (`vg_mux_mp4`), MP4 remux (`vg_remux_mp4`), MP3/M4A (`vg_audio`), VP9→HEVC for 4K.
   Also whisper.cpp for on-device subtitles.
4. **Format planning** (`app/vgbridge.py::_plan`) returns `(kind, formats, photos_ok)` where kind is
   single/merge/convert; downloads separate streams with a comma format spec, then muxes in ObjC.
   YouTube client fallback list: `[None, ['visionos','web_embedded','mweb'], ['android'],
   ['tv_simply','web_safari']]`, with the last-good client cached for 1 hour.

## Storage
Finished files go to **Documents/** (+ `UIFileSharingEnabled`/`LSSupportsOpeningDocumentsInPlace`)
so they appear in the Files app and survive; vault files live outside Documents. MoodyVid writes
to `TMPDIR/moodyvid` which is invisible to the Files app and auto-purged → audio is lost.

## Licensing consequence (important)
VidGrab is GPL-3.0. Copying its code into MoodyVid forces MoodyVid to be GPL-3.0.
Linking GPL ffmpeg (`--enable-libmp3lame`) also forces GPL. An LGPL ffmpeg build (no libmp3lame,
no --enable-gpl) keeps MP4/M4A but drops MP3 encoding.

## Feasibility notes for MoodyVid
- Our CI is GitHub Actions `macos-15` with clang + ldid; Theos works on macOS too but is a big change.
- Adding ffmpeg means building it for iOS in CI (heavy, ~10-20 MB) — do it last.
- JavaScriptCore needs only the system framework + a small C extension — much cheaper win.
