#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The name of the sub-folder of Caches that holds thumbnail jpegs.
FOUNDATION_EXPORT NSString *const MVPathsThumbsDir;

/// Shared filesystem locations, so the ObjC side and the Python engine agree on
/// where downloads live. Must match `MV_DOCUMENTS` in MVPython.m.
@interface MVPaths : NSObject

/// The app's Documents directory — visible in the Files app.
+ (NSString *)documents;

/// Application Support, where state the user should not see (task JSON, logs)
/// lives. Created on demand.
+ (NSString *)applicationSupport;

/// Documents/MoodyVid, where the engine writes downloads. Created on demand.
+ (NSString *)downloads;

/// The folder a category saves into, e.g. Documents/MoodyVid/Videos. Every
/// category folder is created on demand so the Files app shows a tidy tree.
+ (NSString *)directoryForCategory:(NSString *)category;

/// The download categories, in the order the UI lists them. The first entry is
/// "Other", which is also the fallback when a type is unknown.
+ (NSArray<NSString *> *)categories;

/// Picks the category a filename belongs to (Videos, Audio, Documents, ...).
+ (NSString *)categoryForFilename:(NSString *)filename;

/// A filename that is safe to write and never collides with an existing file in
/// `directory`. Adds " (1)", " (2)" … before the extension when needed.
+ (NSString *)uniquePathInDirectory:(NSString *)directory filename:(NSString *)filename;

/// Strips path separators and control characters from a server-supplied name.
+ (NSString *)sanitizeFilename:(NSString *)filename;

/// The yt-dlp cache directory.
+ (NSString *)cache;

/// Where video thumbnail jpegs live. These are caches, not user files.
+ (NSString *)thumbs;

/// A human-readable size such as "345 MB" or "1.2 GB".
+ (NSString *)formatBytes:(long long)bytes;

/// A human-readable speed such as "15.2 MB/s".
+ (NSString *)formatSpeed:(double)bytesPerSecond;

/// A short duration such as "4s", "2m 10s" or "1h 5m".
+ (NSString *)formatDuration:(double)seconds;

/// Free space on the device, in bytes.
+ (long long)freeSpace;

/// Total capacity of the device volume, in bytes.
+ (long long)totalSpace;

@end

NS_ASSUME_NONNULL_END
