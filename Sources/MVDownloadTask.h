#import <Foundation/Foundation.h>
#import "MVSnifferItem.h"
#import "MVQueuePolicy.h"

NS_ASSUME_NONNULL_BEGIN

/// Where a task's bytes come from. The value is persisted, so existing numbers
/// must never be reused for something else.
typedef NS_ENUM(NSInteger, MVTaskSource) {
    MVTaskSourceYtDlp = 0,    ///< the embedded Python engine
    MVTaskSourceDirect = 1,   ///< a plain HTTP(S) file
    MVTaskSourceHLS = 2,      ///< an .m3u8 playlist
    MVTaskSourceTorrent = 3,  ///< a magnet link or .torrent file
    MVTaskSourceDASH = 4,     ///< an .mpd manifest
};

/// The native lifecycle. Its persisted values differ from MVDownloadState;
/// callers must map the two enums explicitly.
typedef NS_ENUM(NSInteger, MVTaskState) {
    MVTaskStateQueued = MVNativeQueued,
    MVTaskStateRunning = MVNativeRunning,
    MVTaskStatePaused = MVNativePaused,
    MVTaskStateCompleted = MVNativeCompleted,
    MVTaskStateFailed = MVNativeFailed,
    MVTaskStateCancelled = MVNativeCancelled,
};

/// One download, whatever engine produces it.
///
/// This is the model the manager owns and the Downloads list reads. It carries
/// resume information such as part offsets and ETag. Continuation depends on
/// the engine, server validators and the partial files still being available.
@interface MVDownloadTask : NSObject

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic) MVTaskSource source;
@property (nonatomic) MVTaskState state;

@property (nonatomic, copy) NSString *url;
/// Optional non-cookie request headers. Cookies are never retained here: the
/// engine selects current browser cookies for each request instead.
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, copy, nullable) NSString *referer;
/// Originating page, or the original manifest URL for manually entered streams.
/// Nested HLS/DASH resources must not treat themselves as the cookie context.
@property (nonatomic, readonly) NSString *resourceContextURL;

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
