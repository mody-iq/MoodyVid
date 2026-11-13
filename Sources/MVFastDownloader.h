#import <Foundation/Foundation.h>
#import "MVDownloadTask.h"

NS_ASSUME_NONNULL_BEGIN

/// Downloads plain HTTP(S) files.
///
/// Streams one or more ranges to `.part` files and joins them without loading
/// the whole download into memory. Partial ranges are reused only when the
/// server provides a matching validator; otherwise the transfer starts fresh.
///
/// Callbacks are always delivered on the main queue.
@interface MVFastDownloader : NSObject

+ (instancetype)shared;

/// Starts (or resumes) `task`. The downloader only moves bytes; the manager owns
/// the task's state and persistence.
- (void)startTask:(MVDownloadTask *)task
         progress:(void (^_Nullable)(MVDownloadTask *task))progress
         finished:(void (^_Nullable)(MVDownloadTask *task))finished
           failed:(void (^_Nullable)(MVDownloadTask *task, NSString *message))failed;

/// Pauses the transfer, keeping the `.part` file so a later start resumes it.
- (void)pauseTask:(MVDownloadTask *)task;

/// Stops the transfer and forgets it. The `.part` file is left in place so the
/// user can resume later; the manager decides whether to delete it.
- (void)cancelTask:(MVDownloadTask *)task;

/// YES while bytes are moving for this task.
- (BOOL)isRunningTask:(MVDownloadTask *)task;

/// Approximate bytes/second per direct transfer, not a global cap. 0 disables
/// it; enabling it for an already-running transfer requires a restart.
@property (nonatomic) long long speedLimit;

/// Deletes every partial file a task left behind: the single-file `.part` and
/// the numbered `.partN` pieces of a segmented transfer. Called when the user
/// really deletes a row, so no orphan bytes stay on disk.
+ (void)removePartFilesForTask:(MVDownloadTask *)task;

@end

NS_ASSUME_NONNULL_END
