#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The name of the sub-folder of Caches that holds thumbnail jpegs.
FOUNDATION_EXPORT NSString *const MVPathsThumbsDir;

/// Shared filesystem locations, so the ObjC side and the Python engine agree on
/// where downloads live. Must match `MV_DOCUMENTS` in MVPython.m.
@interface MVPaths : NSObject

/// The app's Documents directory — visible in the Files app.
+ (NSString *)documents;

/// Documents/MoodyVid, where the engine writes downloads. Created on demand.
+ (NSString *)downloads;

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

@end

NS_ASSUME_NONNULL_END
