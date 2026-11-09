#import <Foundation/Foundation.h>
#import "MVDownloadTask.h"

NS_ASSUME_NONNULL_BEGIN

/// Downloads a DASH stream described by an `.mpd` manifest.
///
/// Like the HLS engine this is native, because iOS has no ffmpeg and blocks
/// subprocesses. It understands the shapes that a downloader actually meets:
/// a static (non-live) manifest, one video representation chosen by bandwidth,
/// and the segment addressing forms `SegmentTemplate` (with `$Number$` or a
/// `SegmentTimeline`), `SegmentList` and a plain `SegmentBase`. The init
/// segment is fetched first, the media segments are fetched a few at a time and
/// joined in order, and a fragmented-MP4 result is an MP4 already.
///
/// Unsupported by design: live manifests (`type="dynamic"`) and any stream that
/// declares `ContentProtection` (Widevine/PlayReady/CENC). Both fail with a
/// clear, localised reason rather than a row that sits at 0% forever.
///
/// Callbacks are always delivered on the main queue.
@interface MVMPDDownloader : NSObject

+ (instancetype)shared;

- (void)startTask:(MVDownloadTask *)task
         progress:(void (^_Nullable)(MVDownloadTask *task))progress
         finished:(void (^_Nullable)(MVDownloadTask *task))finished
           failed:(void (^_Nullable)(MVDownloadTask *task, NSString *message))failed;

- (void)pauseTask:(MVDownloadTask *)task;
- (void)cancelTask:(MVDownloadTask *)task;
- (BOOL)isRunningTask:(MVDownloadTask *)task;

/// A global cap in bytes/second, applied to every transfer. 0 disables it.
@property (nonatomic) long long speedLimit;

/// Deletes the partial files a DASH task left behind.
+ (void)removePartFilesForTask:(MVDownloadTask *)task;

@end

NS_ASSUME_NONNULL_END
