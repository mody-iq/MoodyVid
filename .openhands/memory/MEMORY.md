# MoodyVid memory index
- Build: GitHub Actions; push to main triggers IPA build (`gh run list` to watch). `Sources/*.m` glob picks new files.
- Push needs tokenized remote (GITHUB_TOKEN) — remote gets set with resolved token.
- Player: MVPlayerCenter singleton owns the AVPlayer; floating mini-bar; audio bg mode declared; PiP on.
- Downloads: static quality sheet; list unified; thumbnails cached under Caches/moodyvid-thumbs; resume on launch via resumeInterrupted.
- Settings nil-lock/Premium sections removed.
- See daily logs: 2026-11-06.md, 2026-11-07.md.
