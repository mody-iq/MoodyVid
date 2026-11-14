#import "MVPlaybackHistory.h"
#include <math.h>

static NSString *const MVPlaybackHistoryKey = @"MVPlaybackPositionsV1";
static const NSUInteger MVPlaybackHistoryMaxEntries = 200;

@implementation MVPlaybackHistory {
    NSUserDefaults *_defaults;
}

+ (instancetype)shared {
    static MVPlaybackHistory *history;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ history = [[self alloc] initWithDefaults:NSUserDefaults.standardUserDefaults]; });
    return history;
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) _defaults = defaults;
    return self;
}

- (NSString *)keyForURL:(NSURL *)url {
    if (!url.isFileURL || !url.path.length) return nil;
    return url.path.stringByStandardizingPath;
}

- (NSDictionary *)signatureForPath:(NSString *)path {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    NSNumber *size = attributes[NSFileSize];
    NSDate *modified = attributes[NSFileModificationDate];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || size.unsignedLongLongValue == 0 || !modified) return nil;
    return @{@"size": size, @"modified": @(modified.timeIntervalSince1970)};
}

- (NSMutableDictionary *)entries {
    NSDictionary *stored = [_defaults dictionaryForKey:MVPlaybackHistoryKey];
    return stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

- (double)positionForURL:(NSURL *)url {
    NSString *path = [self keyForURL:url];
    if (!path) return 0;
    NSDictionary *stored = [self entries][path];
    NSDictionary *signature = [self signatureForPath:path];
    if (![stored isKindOfClass:NSDictionary.class] || !signature ||
        ![stored[@"size"] isEqual:signature[@"size"]] || ![stored[@"modified"] isEqual:signature[@"modified"]]) return 0;
    id value = stored[@"position"];
    double position = [value isKindOfClass:NSNumber.class] ? [value doubleValue] : 0;
    return isfinite(position) && position >= 3 ? position : 0;
}

- (void)clearURL:(NSURL *)url {
    NSString *path = [self keyForURL:url];
    if (!path) return;
    NSMutableDictionary *entries = [self entries];
    if (!entries[path]) return;
    [entries removeObjectForKey:path];
    [_defaults setObject:entries forKey:MVPlaybackHistoryKey];
}

- (void)saveURL:(NSURL *)url position:(double)position duration:(double)duration {
    NSString *path = [self keyForURL:url];
    if (!path || !isfinite(position) || !isfinite(duration) || duration <= 0 || position < 0) return;
    // Avoid resuming an already-finished video or tiny accidental starts.
    double ending = MIN(10.0, MAX(1.0, duration * 0.05));
    if (position < 3 || position >= duration - ending) { [self clearURL:url]; return; }
    NSDictionary *signature = [self signatureForPath:path];
    if (!signature) return;
    NSMutableDictionary *entries = [self entries];
    entries[path] = @{@"size": signature[@"size"], @"modified": signature[@"modified"],
                      @"position": @(position), @"updated": @(NSDate.date.timeIntervalSince1970)};
    if (entries.count > MVPlaybackHistoryMaxEntries) {
        NSArray *keys = [entries keysSortedByValueUsingComparator:^NSComparisonResult(id a, id b) {
            double first = [a isKindOfClass:NSDictionary.class] ? [a[@"updated"] doubleValue] : 0;
            double second = [b isKindOfClass:NSDictionary.class] ? [b[@"updated"] doubleValue] : 0;
            return first < second ? NSOrderedAscending : (first > second ? NSOrderedDescending : NSOrderedSame);
        }];
        NSUInteger excess = entries.count - MVPlaybackHistoryMaxEntries;
        for (NSUInteger i = 0; i < excess; i++) [entries removeObjectForKey:keys[i]];
    }
    [_defaults setObject:entries forKey:MVPlaybackHistoryKey];
}
@end
