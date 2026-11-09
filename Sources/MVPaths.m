#import "MVPaths.h"
#include <math.h>

NSString *const MVPathsThumbsDir = @"moodyvid-thumbs";

/// The category folders, in the order the filter chips show them. "Other" is
/// last and is the fallback for a type nothing else matches.
static NSArray<NSString *> *MVCategoryList(void) {
    return @[@"Videos", @"Audio", @"Documents", @"Archives", @"Apps", @"Torrents", @"Other"];
}

/// Every extension the app can name a category for, mapped to its folder.
static NSDictionary<NSString *, NSString *> *MVCategoryMap(void) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            // Videos
            @"mp4": @"Videos", @"m4v": @"Videos", @"mov": @"Videos", @"mkv": @"Videos",
            @"webm": @"Videos", @"avi": @"Videos", @"flv": @"Videos", @"3gp": @"Videos",
            @"ts": @"Videos", @"m2ts": @"Videos", @"mpg": @"Videos", @"mpeg": @"Videos",
            @"wmv": @"Videos", @"ogv": @"Videos", @"m3u8": @"Videos", @"mpd": @"Videos",
            // Audio
            @"mp3": @"Audio", @"m4a": @"Audio", @"aac": @"Audio", @"ogg": @"Audio",
            @"opus": @"Audio", @"flac": @"Audio", @"wav": @"Audio", @"aiff": @"Audio",
            @"wma": @"Audio", @"mka": @"Audio", @"amr": @"Audio",
            // Documents
            @"pdf": @"Documents", @"epub": @"Documents", @"mobi": @"Documents",
            @"txt": @"Documents", @"rtf": @"Documents", @"doc": @"Documents",
            @"docx": @"Documents", @"xls": @"Documents", @"xlsx": @"Documents",
            @"ppt": @"Documents", @"pptx": @"Documents", @"csv": @"Documents",
            @"json": @"Documents", @"xml": @"Documents",
            // Archives
            @"zip": @"Archives", @"rar": @"Archives", @"7z": @"Archives",
            @"tar": @"Archives", @"gz": @"Archives", @"bz2": @"Archives",
            @"xz": @"Archives", @"iso": @"Archives", @"tgz": @"Archives",
            // Apps
            @"ipa": @"Apps", @"apk": @"Apps", @"dmg": @"Apps", @"deb": @"Apps",
            // Torrents
            @"torrent": @"Torrents",
        };
    });
    return map;
}

@implementation MVPaths

+ (NSString *)documents {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

+ (NSString *)applicationSupport {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                                    NSUserDomainMask, YES);
    NSString *base = paths.firstObject;
    if (!base.length) {
        // Application Support always exists on iOS, but fall back to Documents
        // rather than return a nil path that would crash a caller.
        base = [self documents];
    }
    NSString *dir = [base stringByAppendingPathComponent:@"MoodyVid"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

+ (NSArray<NSString *> *)categories { return MVCategoryList(); }

+ (NSString *)categoryForFilename:(NSString *)filename {
    NSString *ext = filename.pathExtension.lowercaseString;
    if (ext.length) {
        NSString *category = MVCategoryMap()[ext];
        if (category) return category;
    }
    return @"Other";
}

+ (NSString *)directoryForCategory:(NSString *)category {
    NSString *name = category.length ? category : @"Other";
    if (![MVCategoryList() containsObject:name]) name = @"Other";
    NSString *dir = [[self downloads] stringByAppendingPathComponent:name];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

+ (NSString *)sanitizeFilename:(NSString *)filename {
    if (!filename.length) return @"file";
    // Server-supplied names are untrusted: they may contain a path, a NUL or a
    // leading dot (a hidden file). Keep the last path component and strip the
    // characters iOS refuses to write.
    NSString *name = filename.lastPathComponent;
    NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|\n\r\t"];
    name = [[name componentsSeparatedByCharactersInSet:illegal] componentsJoinedByString:@"_"];
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([name hasPrefix:@"."]) name = [name substringFromIndex:1];
    if (!name.length) name = @"file";
    if (name.length > 180) {
        // Keep the extension, trim the stem, so an absurd title cannot exceed
        // the filesystem's name limit.
        NSString *ext = name.pathExtension;
        NSString *stem = name.stringByDeletingPathExtension;
        name = [[stem substringToIndex:160] stringByAppendingPathExtension:ext];
    }
    return name;
}

+ (NSString *)uniquePathInDirectory:(NSString *)directory filename:(NSString *)filename {
    NSString *safe = [self sanitizeFilename:filename];
    NSString *path = [directory stringByAppendingPathComponent:safe];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return path;

    NSString *stem = safe.stringByDeletingPathExtension;
    NSString *ext = safe.pathExtension;
    for (NSInteger i = 1; i < 10000; i++) {
        NSString *candidate = [NSString stringWithFormat:@"%@ (%ld)", stem, (long)i];
        if (ext.length) candidate = [candidate stringByAppendingPathExtension:ext];
        NSString *full = [directory stringByAppendingPathComponent:candidate];
        if (![NSFileManager.defaultManager fileExistsAtPath:full]) return full;
    }
    return [directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, safe]];
}

+ (NSString *)downloads {
    NSString *dir = [[self documents] stringByAppendingPathComponent:@"MoodyVid"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

+ (NSString *)cache {
    return [self cachesDir:@"ytdlp-cache"];
}

+ (NSString *)thumbs {
    return [self cachesDir:MVPathsThumbsDir];
}

+ (NSString *)cachesDir:(NSString *)name {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [base stringByAppendingPathComponent:name];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

+ (NSString *)formatBytes:(long long)bytes {
    if (bytes <= 0) return @"—";
    NSByteCountFormatter *f = [NSByteCountFormatter new];
    f.countStyle = NSByteCountFormatterCountStyleFile;
    f.allowedUnits = NSByteCountFormatterUseKB | NSByteCountFormatterUseMB | NSByteCountFormatterUseGB;
    return [f stringFromByteCount:bytes];
}

+ (NSString *)formatSpeed:(double)bytesPerSecond {
    if (bytesPerSecond <= 0) return @"—";
    return [[self formatBytes:(long long)bytesPerSecond] stringByAppendingString:@"/s"];
}

+ (NSString *)formatDuration:(double)seconds {
    if (seconds <= 0 || !isfinite(seconds)) return @"—";
    long s = (long)llround(seconds);
    if (s < 60) return [NSString stringWithFormat:@"%lds", s];
    if (s < 3600) return [NSString stringWithFormat:@"%ldm %lds", s / 60, s % 60];
    return [NSString stringWithFormat:@"%ldh %ldm", s / 3600, (s % 3600) / 60];
}

+ (long long)freeSpace {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfFileSystemForPath:[self documents] error:nil];
    return [attrs[NSFileSystemFreeSize] longLongValue];
}

+ (long long)totalSpace {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfFileSystemForPath:[self documents] error:nil];
    return [attrs[NSFileSystemSize] longLongValue];
}

@end
