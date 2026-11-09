#import <Foundation/Foundation.h>
#import "MVDownloadTask.h"

NS_ASSUME_NONNULL_BEGIN

/// Downloads an HTTP Live Streaming (`.m3u8`) stream.
///
/// iOS has no ffmpeg and blocks subprocesses, so this engine does the job
/// natively: it reads the playlist, fetches every media segment, decrypts the
/// AES-128 ones, joins them in order and — for an MPEG-TS stream — remuxes the
/// result to MP4 with AVFoundation. A fragmented-MP4 stream is already an MP4,
/// so it is just renamed.
///
/// Unsupported by design: FairPlay/SAMPLE-AES encryption and live playlists
/// (no `#EXT-X-ENDLIST`). Both fail with a clear, localised reason instead of a
/// row that sits at 0% forever.
///
/// Callbacks are always delivered on the main queue.
@interface MVHLSDownloader : NSObject

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

/// Deletes the partial files an HLS task left behind.
+ (void)removePartFilesForTask:(MVDownloadTask *)task;

@end

NS_ASSUME_NONNULL_END
