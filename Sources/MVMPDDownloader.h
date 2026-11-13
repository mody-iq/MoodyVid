#import <Foundation/Foundation.h>
#import "MVDownloadTask.h"

NS_ASSUME_NONNULL_BEGIN

/// Downloads a DASH stream described by an `.mpd` manifest.
///
/// Like the HLS engine this is native, because iOS has no ffmpeg and blocks
/// subprocesses. It understands the shapes that a downloader actually meets:
/// a static, single-Period manifest, separate video and audio representations
/// chosen by bandwidth, and `SegmentTemplate`, `SegmentList` and a plain
/// `SegmentBase`. Each track's initialization and media segments are joined
/// independently, then AVFoundation muxes compatible tracks without re-encoding.
/// An audio-only MPD produces an M4A; an MPD without an audio representation can
/// legitimately produce a silent video. Segment files are re-fetched on retry.
///
/// Live, multi-Period, DRM-protected and unsupported WebM/Matroska streams fail
/// clearly. Codec compatibility still depends on AVFoundation and the device.
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

/// Reserved for a future stream throttle; currently not enforced by DASH.
@property (nonatomic) long long speedLimit;

/// Deletes the partial files a DASH task left behind.
+ (void)removePartFilesForTask:(MVDownloadTask *)task;

@end

NS_ASSUME_NONNULL_END
