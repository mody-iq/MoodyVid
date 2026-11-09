#import <Foundation/Foundation.h>
#import "MVDownloadTask.h"

NS_ASSUME_NONNULL_BEGIN

/// Downloads plain HTTP(S) files.
///
/// This checkpoint ships the single-connection path: the body is streamed
/// straight to a `.part` file with NSFileHandle, so a 4 GB video never sits in
/// memory, and an interrupted transfer resumes with a Range request instead of
/// starting over. The segmented (multi-connection) path is added in the next
/// checkpoint on top of exactly this file-writing core, which is why the writes
/// already go through one serial queue per task.
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

/// A global cap in bytes/second, applied to every transfer. 0 disables it.
@property (nonatomic) long long speedLimit;

/// Deletes every partial file a task left behind: the single-file `.part` and
/// the numbered `.partN` pieces of a segmented transfer. Called when the user
/// really deletes a row, so no orphan bytes stay on disk.
+ (void)removePartFilesForTask:(MVDownloadTask *)task;

@end

NS_ASSUME_NONNULL_END
