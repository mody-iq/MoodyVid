#import <Foundation/Foundation.h>
#import "MVDownloadTask.h"
#import "MVSnifferItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Owns every download.
///
/// One place decides how many run at once, which engine gets a task, and when a
/// task finishes. The UI only ever talks to this class, so a direct file, an HLS
/// stream and (later) a torrent all behave the same way in the Downloads list.
///
/// The native direct, HLS, DASH and torrent engines plug in at the same seam.
@interface MVDownloadManager : NSObject

+ (instancetype)shared;

/// Queues a direct HTTP(S) file. Returns the task, which is already in the
/// store, so the caller can show it immediately.
- (MVDownloadTask *)enqueueDirectURL:(NSString *)url
                             headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                             referer:(nullable NSString *)referer
                               title:(nullable NSString *)title
                     suggestedName:(nullable NSString *)suggestedFilename
                            category:(nullable NSString *)category
                            expected:(long long)totalBytes
                             created:(BOOL *_Nullable)created;

/// Queues a sniffed item, choosing the engine from its kind: HLS, DASH,
/// torrent, or a plain HTTP file. A magnet link is queued like any other
/// torrent; tracker-backed v1 magnets can fetch metadata through BEP 9.
- (MVDownloadTask *)enqueueItem:(MVSnifferItem *)item;

/// Same, but reports whether a new task was created. `added` is set to NO when
/// the URL was already in the list (the existing row is moved to the top), so
/// the caller can say "Already in downloads" instead of pretending it queued.
- (MVDownloadTask *)enqueueItem:(MVSnifferItem *)item added:(BOOL *_Nullable)added;

/// Resumes a paused or failed task.
- (void)resumeTask:(MVDownloadTask *)task;
/// Pauses a running task, keeping its partial file.
- (void)pauseTask:(MVDownloadTask *)task;
/// Stops a task; `deleteFile` also removes the partial/finished file.
- (void)cancelTask:(MVDownloadTask *)task deleteFile:(BOOL)deleteFile;
/// Removes a finished task from the list (and its file when asked).
- (void)removeTask:(MVDownloadTask *)task deleteFile:(BOOL)deleteFile;

/// Pauses every running task and empties the queue.
- (void)pauseAll;
/// Resumes every paused task.
- (void)resumeAll;
/// Retries every failed task.
- (void)retryAllFailed;

/// Moves a task up or down the queue.
- (void)moveTaskUp:(MVDownloadTask *)task;
- (void)moveTaskDown:(MVDownloadTask *)task;

/// Re-queues tasks that were interrupted (the app was killed or restarted).
- (void)resumeInterrupted;

/// How many direct transfers are moving right now.
@property (nonatomic, readonly) NSUInteger runningCount;
/// The most a single direct task may use. Persisted.
@property (nonatomic) NSUInteger maxConnections;
/// How many tasks run at once. Persisted.
@property (nonatomic) NSUInteger maxConcurrentTasks;
/// Approximate per-direct-transfer cap in bytes/second; 0 is unlimited.
/// Other engines are not throttled. Persisted.
@property (nonatomic) long long speedLimit;
/// When YES, both download queues wait for an observed Wi-Fi default path
/// before starting. This is not a cellular firewall for running sockets.
@property (nonatomic) BOOL wifiOnly;

@end

NS_ASSUME_NONNULL_END
