#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Native media jobs yt-dlp cannot do by itself on iOS.
///
/// iOS has no ffmpeg and blocks subprocesses, so the downloader cannot merge a
/// separate video stream with its audio inside Python. These helpers do the
/// same jobs with AVFoundation (muxing a perfectly compatible MP4) and with a
/// bundled LAME encoder (MP3). Everything runs off the main thread.
@interface MVMediaConverter : NSObject

/// Muxes a video file and an audio file into one MP4 (AAC + H.264 stay as-is;
/// the remux copies both tracks without re-encoding). `outPath` must end in
/// `.mp4`. Completion fires on the main queue.
+ (void)muxVideo:(NSString *)videoPath
           audio:(NSString *)audioPath
              to:(NSString *)outPath
      completion:(void (^)(BOOL ok, NSString *_Nullable error))completion;

/// Encodes an audio file (AAC/M4A/WAV from AVFoundation) into an MP3 via the
/// bundled LAME encoder. When LAME is not available the input is copied as-is
/// to `outPath` unchanged and `ok` is still NO — callers then keep the original
/// `outPath` as a plain audio file. Completion fires on the main queue.
+ (void)convertToMP3:(NSString *)audioPath
                  to:(NSString *)outPath
          completion:(void (^)(BOOL ok, NSString *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END