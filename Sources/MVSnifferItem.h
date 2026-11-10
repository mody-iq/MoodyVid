#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What a sniffed URL turned out to be. The value decides the icon, the label
/// and which engine will eventually fetch it.
typedef NS_ENUM(NSInteger, MVSniffKind) {
    MVSniffKindUnknown = 0,
    MVSniffKindVideo,
    MVSniffKindAudio,
    MVSniffKindImage,
    MVSniffKindDocument,
    MVSniffKindArchive,
    MVSniffKindApp,
    MVSniffKindHLS,       ///< .m3u8 — handled by the HLS engine (later phase)
    MVSniffKindDASH,      ///< .mpd  — not supported, offered to yt-dlp
    MVSniffKindTorrent,   ///< magnet: or .torrent — handled by the torrent engine (later phase)
    MVSniffKindPage,      ///< a watch/shorts page, not a file — fetched by yt-dlp
};

/// One media or file link the page touched.
///
/// A plain value object: the browser's sniffer creates it, the sheet renders it,
/// and the download manager consumes it. Everything here is already validated
/// (absolute http(s)/magnet URL), so consumers do not re-check.
@interface MVSnifferItem : NSObject

@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *pageURL;
@property (nonatomic, copy) NSString *pageTitle;
@property (nonatomic, copy, nullable) NSString *referer;
@property (nonatomic, copy, nullable) NSString *mimeType;
@property (nonatomic, copy, nullable) NSString *suggestedFilename;
@property (nonatomic) MVSniffKind kind;
/// Content-Length from the probe, or -1 when unknown (HLS playlists, magnet).
@property (nonatomic) long long totalBytes;
/// YES when the server accepts Range requests, so the segmented engine can use
/// several connections. NO means a single connection.
@property (nonatomic) BOOL acceptsRanges;
/// YES once the probe has run (even if it failed), so the UI can stop saying
/// "checking…" and the store does not re-probe in a loop.
@property (nonatomic) BOOL probed;
@property (nonatomic) NSTimeInterval foundAt;

/// YES for the kinds that can be queued straight away.
@property (nonatomic, readonly) BOOL isDownloadable;
/// YES for the kinds this app can fetch with its own engine (not yt-dlp).
@property (nonatomic, readonly) BOOL isDirectFile;
/// YES for magnet links and .torrent files.
@property (nonatomic, readonly) BOOL isTorrent;
/// YES for a video page (a watch/shorts page) rather than a media file. The page
/// is downloaded by yt-dlp, not by the direct engine.
@property (nonatomic, readonly) BOOL isPage;

+ (instancetype)itemWithURL:(NSString *)url
                    pageURL:(nullable NSString *)pageURL
                  pageTitle:(nullable NSString *)pageTitle
                       mime:(nullable NSString *)mime;

/// The name to show in a row: the server's filename, else the URL's last
/// component, else the host.
- (NSString *)displayName;

/// The kind implied by a URL and/or MIME type. Exposed so the download manager
/// can classify a URL that did not come from the sniffer.
+ (MVSniffKind)kindForURL:(NSString *)url mime:(nullable NSString *)mime;

/// YES when the URL is a page a single-video extractor can open, even though the
/// page itself is not a media file. YouTube (and similar sites) play through a
/// blob, so the sniffer finds no downloadable link and the sheet looks empty;
/// the page URL is still what yt-dlp needs, so the sheet offers it as a row.
+ (BOOL)isVideoPageURL:(nullable NSString *)url;

/// The SF Symbol that stands for a kind.
+ (NSString *)symbolForKind:(MVSniffKind)kind;

/// The localisation key that names a kind ("Video", "Audio", …).
+ (NSString *)titleKeyForKind:(MVSniffKind)kind;

@end

NS_ASSUME_NONNULL_END
