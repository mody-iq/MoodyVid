# MoodyVid memory index
Details live in the daily logs: 2026-11-06.md, 2026-11-09.md, 2026-11-10.md, 2026-11-11.md.

## Build / repo
- GitHub Actions builds the IPA; push to `main` triggers it (`gh run list`, `gh run watch <id>`). `Sources/*.m` glob picks up new files. Push needs the tokenized remote.
- Side-by-side builds: `scripts/build.sh` reads app identity from env (MV_APP_NAME / MV_BUNDLE_ID / MV_DISPLAY_NAME / MV_ICON_TOP / MV_ICON_BOTTOM), shipping defaults otherwise. Two apps coexist only if CFBundleIdentifier differs. Workflow has a `variant` dispatch input → `com.mody.moodyvid.test`.
- `scripts/build.sh` fetches yt-dlp nightly by explicit tag then stable, with a `fetch()` retry helper. LAME is built from source for MP3.
- `scripts/check-strings.py` verifies every `[MVLang t:@"…"]` literal exists in the table and reports duplicates. Run it after touching UI strings; it gates the build.
- `scripts/torrent-tests.sh` (macOS-only, system clang) gates the torrent core in CI before the IPA build.

## Compile traps (each cost a real build)
- New system framework → add `-framework <Name>` to `scripts/build.sh`. `UTType*` globals are weak-linked, so they compile but fail to LINK with `_UTTypePlainText` undefined.
- `nullable` is NOT usable inside an `NS_ASSUME_NONNULL` block — use `_Nullable`.
- A bare message-send inside an `@[...]` literal does not parse; assign to a local first.
- A `copy` block property must be nil'd in `-prepareForReuse`; declare its setter explicitly in the .m.
- Any property whose name starts with `init` makes clang read the getter as an init method → rename (`mapSegment`, not `initSegment`).
- `WKWebView findString:withConfiguration:completionHandler:`; `stringByRemovingPercentEncoding`; `WKContentRuleList` has no `.rules`.
- `.CGColor` after `?:` mis-binds → resolve colors into locals first. Big heredoc writes truncate; use file_editor/python.

## UI / theme
- One card language across Home/Downloads/Files/More. Shared components: `MVTaskCardCell` (+`MVCardContent`), `MVFileCardCell`, `MVStatusChipsView`, `MVSectionHeader`, `MVEmptyStateView`, `MVFloatingAddButton`, `MVTypeFilterSheet`, `MVDetailsSheet`, `MVDownloadActions`, `MVDownloadRow`. `MVTaskCell`/`MVDownloadCell` are GONE — `MVTaskCardCell` renders every download row, so the old "two cell classes, never cast" crash trap no longer applies. Cards are plain UIViews styled with `+[MVTheme applyCardStyle:cornerRadius:]`.
- `MVTheme.iconTint` is the ONLY tint for decorative icon chips (settings rows, file tiles, tabs). Status colours (success/warning/danger) are reserved for real state — a card tint comes from `tintForRow:` and means status, so don't reuse them as decoration.
- `MVThumbnailCache` (memory + `MVPaths.thumbs`, keyed path+size+mtime) grabs a real video frame via `AVAssetImageGenerator` when a file has no cached artwork. `MVFileCardCell.representedPath` guards a late frame against cell reuse.
- A `UITableView.tableHeaderView` is measured the first time it is assigned, when the table is still zero-width, so it can be left taller than its content (the blank band under a search bar). Re-measure in `viewDidLayoutSubviews` and reassign ONLY when the height changed — reassigning mid-scroll cancels the gesture.
- Layout tokens + fonts live in `MVTheme` (`cardCornerRadius`/`cardSpacing`/`screenPadding`/`minTouchTarget`, `cardTitleFont`/`cardDetailFont`/`sectionHeaderFont`/`chipFont`, `applyIconTileStyle:tint:`).
- Surfaces are FLAT (2026-11-11, supersedes the earlier glass look): `applyCardStyle:` is a solid fill — no blur, no border, no shadow. The `kGlassBlurTag` blur view is gone; `glassCard` returns an opaque `card`. The player mini bar, parked card, FAB, sniffer button and contact sheet backdrop also lost their blur + shadow. Nav/tab bars use `configureWithOpaqueBackground` + a hairline `shadowColor`; `prefersLargeTitles = NO` everywhere; the inline title font (semibold 17) is set once in `MVTabBarController`. The shell wallpaper is gone — each tab paints its own via `applyWallpaperTo:`; trait changes still call `applyTheme`.
- Wallpapers: 10 keys, gradient or raster (`MVTheme.wallpaperUsesImage:`). `CAGradientLayer.colors` takes CGColorRefs — resolve dynamic colors and re-apply via `refreshWallpaperIfPattern:` on trait change.
- Settings: Appearance/Wallpaper rows present action sheets (Language pattern); swatches via `wallpaperSwatchViewForName:`. Home brand = `MVGradientLabel` (kCGTextClip) + glassy badge.
- Auto Layout: a scroll view's content pinned to its FRAME anchors can never scroll (content width == visible width) and fights fixed-width children. Pin to `scroll.contentLayoutGuide`, take the height from `frameLayoutGuide`, and set a horizontal stack's `alignment` (default Fill stretches a fixed-height tile).

## Files tab (2026-11-11)
- Kind bar (All/Video/Audio/Other). Video/Audio/Other walk the WHOLE tree by extension (`pathsMatchingKind:underPath:`), so a download is found in any folder; All browses folders. Sort/new-folder bar buttons are disabled outside All.
- `visibleEntries` returns absolute PATHS, not names; every row call site reads it and takes `path.lastPathComponent`. It is memoised against the kind|filter|folder key — without the cache a kind filter re-walks the tree once per row. `refresh` always clears the cache.
- A kind change inside a subfolder pops to root AND copies `filterKind` onto `viewControllers.firstObject`, or the root stays on All.
- "Show in Files" (finished download) posts `MVRevealFileNotification` → `MVTabBarController` switches to tab 2, pops to root, calls `revealPath:`. That pushes the containing folder when needed, falls back to All if the kind filter hides the target, scrolls, then flashes the cell via `MVFileCardCell.flashHighlight`. Scroll and flash must be split across `dispatch_async(main)` — the cell is not dequeued until the scroll lands. `revealPath:` defers to `revealTarget` when `!isViewLoaded || view.window == nil` (a tab switch has not attached the window yet), and `viewWillAppear` does the work.

## Player
- `MVPlayerCenter` singleton owns the AVPlayer; floating mini bar; audio bg mode declared. The full player is a CUSTOM `MVFullPlayerViewController` (AVPlayerLayer + bar), NOT AVKit — AVPlayerViewController pauses its player on dismissal (the "audio stops on shrink" bug). Never transfer the player to another VC; `hideFloatingBar`/`showFloatingBar` control the mini bar. Files tab plays videos IN a card (in-tab), not a modal.

## Downloads
- Tab shows BOTH engines in one list via `MVDownloadRow` (wraps MVDownloadRecord and MVDownloadTask). New row kind = extend MVDownloadRow + cellForRow.
- `MVDownloadManager` queue (maxConcurrentTasks, maxConnections, speedLimit, wifiOnly); `MVFastDownloader` (multi-connection segmented with Range resume + ETag guard, single-connection fallback); `MVHLSDownloader` (m3u8, AES-128 CBC, fMP4, TS→MP4 remux; live/SAMPLE-AES fail with a localized reason); `MVMPDDownloader` (SegmentTemplate/$Time$/SegmentTimeline/SegmentList/SegmentBase; live/ContentProtection fail). `MVTaskStore` = JSON in App Support, atomic and corruption-tolerant.
- High quality (>=1080p and "best") = two fragments + native mux, because iOS has no ffmpeg. Fragments are `.video.`/`.audio.`; the mux/MP3 target MUST differ from its source (`derivedPathFor:`) — the old code muxed onto the video file itself and produced an empty result. `+[MVMediaConverter hasAudioTrack:]` skips the audio download when the picture already carries sound.
- Pause/resume: a pause can't suspend yt-dlp, so it unwinds like a cancel but keeps the `.part`. `MVPython` has `pausedTasks` + `mvnative.paused(task)`; `"paused"` sets `MVDownloadStatePaused` (keeps fragments). A paused merged job must KEEP its `.video` fragment. `finishJob:` bails when `_running[id]` is a *different* job, because a resume can queue a replacement before the paused callback lands.
- yt-dlp page downloads need the LIVE page URL — `tab.url` lags on SPAs, so read `webView.URL`. YouTube `android` client works; web styles are bot-blocked and datacenter IPs are blocked, so device testing matters.

## Torrent / browser
- Torrent engine is Foundation-only (`Sources/MVTorrent*.m` + MVBencode/MVSHA1/MVMagnet): peer wire, storage, tracker announce. Magnets resolve via BEP 9 (placeholder metadata + trackers → BEP 10 extended handshake → 16 KiB metadata pieces → verify against the info-hash → re-wrap as a one-key .torrent). TRAP: that wrap must append the RAW info-dict bytes (`d4:info` + bytes + `e`); bencoding `@{@"info": bytes}` makes it a length-prefixed STRING and the info-hash never matches. Helper: `+[MVBencode torrentDataWithInfoDict:]`.
- Browser: multi-tab (max 8), home page (shortcuts/bookmarks/history), tab grid, sniffer (injected at documentStart + per-tab store + HEAD/Range probe with cookies+referer), ad blocker, found-media sheet. Popups without a user gesture are dropped; magnet links route to the manager.
- Ad blocker (`MVAdBlocker`): WebKit rejects the WHOLE list if one rule is invalid (`WKErrorDomain error 6`). `if-domain` maps to the PAGE URL, not the request — use a `url-filter` on the request host. On refusal, `probeRules:` recompiles rules one by one and keeps the accepted ones (`MoodyVidAdsGood`). Rules are built at runtime via `NSJSONSerialization` in `MVAdBlockRules()`. If ads appear, grep the log for `adblock:`.
- `MVPython` `startOnQueue` imports `downloader` (yt-dlp) at launch so the first download doesn't stall.
