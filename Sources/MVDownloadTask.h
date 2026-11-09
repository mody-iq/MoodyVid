#import <Foundation/Foundation.h>
#import "MVSnifferItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Where a task's bytes come from. The value is persisted, so existing numbers
/// must never be reused for something else.
typedef NS_ENUM(NSInteger, MVTaskSource) {
    MVTaskSourceYtDlp = 0,    ///< the embedded Python engine
    MVTaskSourceDirect = 1,   ///< a plain HTTP(S) file
    MVTaskSourceHLS = 2,      ///< an .m3u8 playlist (engine lands in a later phase)
    MVTaskSourceTorrent = 3,  ///< a magnet link or .torrent (later phase)
};

/// The lifecycle of a task. Matches MVDownloadState's ordering where they
/// overlap so the Downloads list can render either with one switch.
typedef NS_ENUM(NSInteger, MVTaskState) {
    MVTaskStateQueued = 0,
    MVTaskStateRunning = 1,
    MVTaskStatePaused = 2,
    MVTaskStateCompleted = 3,
    MVTaskStateFailed = 4,
    MVTaskStateCancelled = 5,
};

/// One download, whatever engine produces it.
///
/// This is the model the manager owns and the Downloads list reads. It carries
/// everything the engines need to resume (part offsets, ETag) so a relaunch can
/// continue instead of starting over.
@interface MVDownloadTask : NSObject

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic) MVTaskSource source;
@property (nonatomic) MVTaskState state;

@property (nonatomic, copy) NSString *url;
/// Headers the engine must replay (Referer, Cookie, User-Agent).
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, copy) NSString *referer;

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *suggestedFilename;
@property (nonatomic, copy) NSString *category;
/// Final path once the file exists.
@property (nonatomic, copy, nullable) NSString *path;
/// The partially downloaded file while the task runs.
@property (nonatomic, copy, nullable) NSString *tempPath;

@property (nonatomic) long long totalBytes;
@property (nonatomic) long long doneBytes;
@property (nonatomic) double speed;
@property (nonatomic) double eta;
@property (nonatomic, copy, nullable) NSString *error;
/// A transient phase message ("Merging…") shown in place of the progress line.
@property (nonatomic, copy, nullable) NSString *phase;

@property (nonatomic) BOOL acceptsRanges;
@property (nonatomic) NSUInteger connections;
/// The byte plan of a multi-connection transfer, as @[@(start), @(end)] pairs
/// (inclusive). Empty for a single-connection transfer. Persisted so a relaunch
/// can resume each segment where it stopped instead of re-planning.
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *segments;
@property (nonatomic, copy, nullable) NSString *etag;
@property (nonatomic, copy, nullable) NSString *lastModified;

@property (nonatomic) NSTimeInterval createdAt;
@property (nonatomic) NSTimeInterval updatedAt;
/// Monotonic ordering for the queue (lower runs first).
@property (nonatomic) NSInteger priority;

/// 0…1. Derived, so it is always consistent with the byte counters.
@property (nonatomic, readonly) double progress;
@property (nonatomic, readonly) BOOL isActive;
@property (nonatomic, readonly) BOOL isFinished;

+ (instancetype)taskFromDictionary:(NSDictionary *)dict;
- (NSDictionary *)dictionary;

/// YES when the two tasks represent the same download (same URL), so a re-add
/// can be turned into "move to top" instead of a duplicate.
- (BOOL)matchesURL:(NSString *)url;

@end

NS_ASSUME_NONNULL_END
