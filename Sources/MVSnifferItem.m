#import "MVSnifferItem.h"

/// Every extension the sniffer considers media or a file worth offering, mapped
/// to the kind that stands for it. A URL's extension alone is enough to classify
/// it, and a Content-Type covers the URLs that have none (most CDNs).
static NSDictionary<NSString *, NSNumber *> *MVKindByExtension(void) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"mp4": @(MVSniffKindVideo), @"m4v": @(MVSniffKindVideo),
            @"mov": @(MVSniffKindVideo), @"webm": @(MVSniffKindVideo),
            @"mkv": @(MVSniffKindVideo), @"avi": @(MVSniffKindVideo),
            @"flv": @(MVSniffKindVideo), @"3gp": @(MVSniffKindVideo),
            @"mpg": @(MVSniffKindVideo), @"mpeg": @(MVSniffKindVideo),
            @"ts": @(MVSniffKindVideo),  @"m2ts": @(MVSniffKindVideo),
            @"wmv": @(MVSniffKindVideo), @"ogv": @(MVSniffKindVideo),

            @"mp3": @(MVSniffKindAudio), @"m4a": @(MVSniffKindAudio),
            @"aac": @(MVSniffKindAudio), @"ogg": @(MVSniffKindAudio),
            @"opus": @(MVSniffKindAudio), @"flac": @(MVSniffKindAudio),
            @"wav": @(MVSniffKindAudio), @"aiff": @(MVSniffKindAudio),
            @"wma": @(MVSniffKindAudio), @"mka": @(MVSniffKindAudio),
            @"amr": @(MVSniffKindAudio),

            @"jpg": @(MVSniffKindImage), @"jpeg": @(MVSniffKindImage),
            @"png": @(MVSniffKindImage), @"gif": @(MVSniffKindImage),
            @"webp": @(MVSniffKindImage), @"heic": @(MVSniffKindImage),
            @"bmp": @(MVSniffKindImage), @"tiff": @(MVSniffKindImage),

            @"pdf": @(MVSniffKindDocument), @"epub": @(MVSniffKindDocument),
            @"mobi": @(MVSniffKindDocument), @"txt": @(MVSniffKindDocument),
            @"rtf": @(MVSniffKindDocument), @"doc": @(MVSniffKindDocument),
            @"docx": @(MVSniffKindDocument), @"xls": @(MVSniffKindDocument),
            @"xlsx": @(MVSniffKindDocument), @"ppt": @(MVSniffKindDocument),
            @"pptx": @(MVSniffKindDocument), @"csv": @(MVSniffKindDocument),

            @"zip": @(MVSniffKindArchive), @"rar": @(MVSniffKindArchive),
            @"7z": @(MVSniffKindArchive), @"tar": @(MVSniffKindArchive),
            @"gz": @(MVSniffKindArchive), @"bz2": @(MVSniffKindArchive),
            @"xz": @(MVSniffKindArchive), @"iso": @(MVSniffKindArchive),
            @"tgz": @(MVSniffKindArchive),

            @"ipa": @(MVSniffKindApp), @"apk": @(MVSniffKindApp),
            @"dmg": @(MVSniffKindApp), @"deb": @(MVSniffKindApp),

            @"m3u8": @(MVSniffKindHLS), @"mpd": @(MVSniffKindDASH),
            @"torrent": @(MVSniffKindTorrent),
        };
    });
    return map;
}

@implementation MVSnifferItem

+ (instancetype)itemWithURL:(NSString *)url
                    pageURL:(NSString *)pageURL
                  pageTitle:(NSString *)pageTitle
                       mime:(NSString *)mime {
    MVSnifferItem *item = [MVSnifferItem new];
    item.url = url ?: @"";
    item.pageURL = pageURL ?: @"";
    item.pageTitle = pageTitle ?: @"";
    item.mimeType = mime;
    item.kind = [MVSnifferItem kindForURL:url mime:mime];
    item.totalBytes = -1;
    item.foundAt = NSDate.date.timeIntervalSince1970;
    return item;
}

+ (MVSniffKind)kindForURL:(NSString *)url mime:(NSString *)mime {
    NSString *lower = url.lowercaseString ?: @"";
    if ([lower hasPrefix:@"magnet:"]) return MVSniffKindTorrent;

    NSString *ext = @"";
    NSURLComponents *components = [NSURLComponents componentsWithString:url];
    if (components) {
        // pathExtension on the path (not the whole URL) so a query string such as
        // "?token=abc.mp4" cannot fool the classifier.
        ext = components.path.pathExtension.lowercaseString;
    }
    if (!ext.length) ext = url.pathExtension.lowercaseString;

    NSNumber *byExtension = MVKindByExtension()[ext];
    if (byExtension) return (MVSniffKind)byExtension.integerValue;

    NSString *type = mime.lowercaseString;
    if (type.length) {
        if ([type hasPrefix:@"video/"]) return MVSniffKindVideo;
        if ([type hasPrefix:@"audio/"]) return MVSniffKindAudio;
        if ([type hasPrefix:@"image/"]) return MVSniffKindImage;
        if ([type containsString:@"mpegurl"] || [type containsString:@"m3u"]) return MVSniffKindHLS;
        if ([type containsString:@"dash+xml"]) return MVSniffKindDASH;
        if ([type containsString:@"bittorrent"]) return MVSniffKindTorrent;
        if ([type isEqualToString:@"application/pdf"] || [type hasPrefix:@"text/"]) return MVSniffKindDocument;
        if ([type containsString:@"zip"] || [type containsString:@"rar"] ||
            [type containsString:@"tar"] || [type containsString:@"7z"]) return MVSniffKindArchive;
        if ([type containsString:@"octet-stream"]) return MVSniffKindUnknown;
    }
    return MVSniffKindUnknown;
}

+ (NSString *)symbolForKind:(MVSniffKind)kind {
    switch (kind) {
        case MVSniffKindVideo:    return @"film";
        case MVSniffKindAudio:    return @"music.note";
        case MVSniffKindImage:    return @"photo";
        case MVSniffKindDocument: return @"doc.text";
        case MVSniffKindArchive:  return @"archivebox";
        case MVSniffKindApp:      return @"app.badge";
        case MVSniffKindHLS:      return @"dot.radiowaves.left.and.right";
        case MVSniffKindDASH:     return @"dot.radiowaves.left.and.right";
        case MVSniffKindTorrent:  return @"arrow.up.arrow.down.circle";
        default:                  return @"doc";
    }
}

+ (NSString *)titleKeyForKind:(MVSniffKind)kind {
    switch (kind) {
        case MVSniffKindVideo:    return @"Video";
        case MVSniffKindAudio:    return @"Audio";
        case MVSniffKindImage:    return @"Image";
        case MVSniffKindDocument: return @"Document";
        case MVSniffKindArchive:  return @"Archive";
        case MVSniffKindApp:      return @"App";
        case MVSniffKindHLS:      return @"Stream (HLS)";
        case MVSniffKindDASH:     return @"Stream (DASH)";
        case MVSniffKindTorrent:  return @"Torrent";
        default:                  return @"File";
    }
}

- (BOOL)isDirectFile {
    switch (self.kind) {
        case MVSniffKindVideo:
        case MVSniffKindAudio:
        case MVSniffKindImage:
        case MVSniffKindDocument:
        case MVSniffKindArchive:
        case MVSniffKindApp:
            return YES;
        default:
            return NO;
    }
}

- (BOOL)isTorrent { return self.kind == MVSniffKindTorrent; }

- (BOOL)isDownloadable {
    // HLS/DASH/Torrent are downloadable in principle but their engines arrive in
    // later checkpoints; the UI still lists them and routes them then. Reporting
    // them as downloadable here keeps the row honest ("downloadable, pending
    // engine") instead of hiding a real link from the user.
    return self.url.length > 0;
}

- (NSString *)displayName {
    if (self.suggestedFilename.length) return self.suggestedFilename;
    if (self.isTorrent && [self.url.lowercaseString hasPrefix:@"magnet:"]) {
        // A magnet's dn= parameter is the display name the user expects.
        NSURLComponents *c = [NSURLComponents componentsWithString:self.url];
        for (NSURLQueryItem *q in c.queryItems) {
            if ([q.name isEqualToString:@"dn"] && q.value.length) return q.value;
        }
        return self.pageTitle.length ? self.pageTitle : self.url;
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:self.url];
    NSString *last = components.path.lastPathComponent;
    if (last.length && ![last isEqualToString:@"/"]) {
        return [last stringByRemovingPercentEncoding] ?: last;
    }
    return components.host ?: self.url;
}

@end
