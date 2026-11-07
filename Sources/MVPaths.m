#import "MVPaths.h"
#include <math.h>

NSString *const MVPathsThumbsDir = @"moodyvid-thumbs";

@implementation MVPaths

+ (NSString *)documents {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
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
