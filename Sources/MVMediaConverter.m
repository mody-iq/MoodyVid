#import "MVMediaConverter.h"
#import "MVLang.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <stdlib.h>

// The MP3 encoder (see build.sh). Falls back to AAC/m4a when not present.
#if __has_include(<lame.h>)
#import <lame.h>
#define MV_HAS_LAME 1
#else
#define MV_HAS_LAME 0
#endif

#if MV_HAS_LAME
/// LAME is handed at most this many frames per call, which is what the MP3
/// output buffer in -convertToMP3:to:completion: is sized for.
static const int kMaxFrames = 8192;

@interface MVMediaConverter ()
/// Encodes the whole frames in `pending`, keeping a trailing partial frame.
+ (void)drainPending:(NSMutableData *)pending
              toLame:(lame_global_flags *)gfp
              output:(unsigned char *)mp3buf
         outCapacity:(size_t)outCapacity
                file:(FILE *)fp
            channels:(int)channels;
@end
#endif

@implementation MVMediaConverter

+ (void)muxVideo:(NSString *)videoPath
           audio:(NSString *)audioPath
              to:(NSString *)outPath
      completion:(void (^)(BOOL, NSString *_Nullable))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = NO;
        NSString *message = [MVLang t:@"Merge failed"];
        NSFileManager *fm = NSFileManager.defaultManager;
        @autoreleasepool {
            if (!videoPath.length || !audioPath.length || !outPath.length ||
                [outPath isEqualToString:videoPath] || [outPath isEqualToString:audioPath]) {
                message = [MVLang t:@"Could not read this file"];
            } else {
                AVURLAsset *video = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:videoPath]];
                AVURLAsset *audio = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:audioPath]];
                AVAssetTrack *vTrack = [video tracksWithMediaType:AVMediaTypeVideo].firstObject;
                // If the video is already multiplexed, insert its own audio.
                // Merely observing it without inserting it would export silence.
                AVAssetTrack *aTrack = [video tracksWithMediaType:AVMediaTypeAudio].firstObject ?:
                    [audio tracksWithMediaType:AVMediaTypeAudio].firstObject;
                if (!vTrack) {
                    message = [MVLang t:@"No video track"];
                } else if (!aTrack) {
                    message = [MVLang t:@"No audio track"];
                } else {
                    AVMutableComposition *mix = [AVMutableComposition composition];
                    AVMutableCompositionTrack *vt = [mix addMutableTrackWithMediaType:AVMediaTypeVideo
                                                                    preferredTrackID:kCMPersistentTrackID_Invalid];
                    AVMutableCompositionTrack *at = [mix addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                    preferredTrackID:kCMPersistentTrackID_Invalid];
                    CMTimeRange vrange = vTrack.timeRange;
                    CMTimeRange arange = aTrack.timeRange;
                    CMTime span = CMTIME_COMPARE_INLINE(arange.duration, <, vrange.duration) ? arange.duration : vrange.duration;
                    NSError *insertError = nil;
                    BOOL valid = vt && at && CMTIME_IS_NUMERIC(vrange.duration) && CMTIME_IS_NUMERIC(span) &&
                        CMTIME_COMPARE_INLINE(vrange.duration, >, kCMTimeZero) && CMTIME_COMPARE_INLINE(span, >, kCMTimeZero);
                    BOOL videoInserted = valid && [vt insertTimeRange:vrange ofTrack:vTrack atTime:kCMTimeZero error:&insertError];
                    BOOL audioInserted = videoInserted && [at insertTimeRange:CMTimeRangeMake(arange.start, span)
                                                                      ofTrack:aTrack atTime:kCMTimeZero error:&insertError];
                    if (!videoInserted || !audioInserted) {
                        message = insertError.localizedDescription ?: [MVLang t:@"Merge failed"];
                    } else {
                        vt.preferredTransform = vTrack.preferredTransform;
                        [fm removeItemAtPath:outPath error:nil];
                        AVAssetExportSession *export = [AVAssetExportSession exportSessionWithAsset:mix
                                                                           presetName:AVAssetExportPresetPassthrough];
                        if (export) {
                            export.outputURL = [NSURL fileURLWithPath:outPath];
                            export.outputFileType = AVFileTypeMPEG4;
                            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                            [export exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
                            long timedOut = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600LL * NSEC_PER_SEC)));
                            if (timedOut) {
                                [export cancelExport];
                                // The exporter may still be closing the file. Remove it
                                // after its callback, not while a new writer can reuse it.
                                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                                    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
                                    [fm removeItemAtPath:outPath error:nil];
                                });
                            } else if (export.status == AVAssetExportSessionStatusCompleted) {
                                AVURLAsset *result = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:outPath]];
                                long long size = [[fm attributesOfItemAtPath:outPath error:nil][NSFileSize] longLongValue];
                                ok = size > 0 && [result tracksWithMediaType:AVMediaTypeVideo].count > 0 &&
                                    [result tracksWithMediaType:AVMediaTypeAudio].count > 0;
                                if (ok) message = nil;
                                else [fm removeItemAtPath:outPath error:nil];
                            } else {
                                message = export.error.localizedDescription ?: message;
                                [fm removeItemAtPath:outPath error:nil];
                            }
                        }
                    }
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(ok, message); });
    });
}

+ (BOOL)hasVideoTrack:(NSString *)path {
    if (!path.length) return NO;
    AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:path]];
    return [asset tracksWithMediaType:AVMediaTypeVideo].count > 0;
}

+ (BOOL)hasAudioTrack:(NSString *)path {
    if (!path.length) return NO;
    AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:path]];
    return [asset tracksWithMediaType:AVMediaTypeAudio].count > 0;
}

+ (void)remuxToMP4:(NSString *)path
                to:(NSString *)outPath
        completion:(void (^)(BOOL, NSString *_Nullable))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = NO;
        NSString *error = nil;
        @autoreleasepool {
            AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:path]];
            AVAssetTrack *vTrack = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
            if (!vTrack) {
                error = [MVLang t:@"No video track"];
            } else {
                AVMutableComposition *mix = [AVMutableComposition composition];
                NSError *verr = nil;
                AVMutableCompositionTrack *vt = [mix addMutableTrackWithMediaType:AVMediaTypeVideo
                                                                preferredTrackID:kCMPersistentTrackID_Invalid];
                CMTime videoSpan = vTrack.timeRange.duration;
                [vt insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoSpan)
                            ofTrack:vTrack atTime:kCMTimeZero error:&verr];
                AVAssetTrack *aTrack = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
                if (aTrack && !verr) {
                    AVMutableCompositionTrack *at = [mix addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                    preferredTrackID:kCMPersistentTrackID_Invalid];
                    CMTime audioSpan = aTrack.timeRange.duration;
                    CMTime span = CMTIME_COMPARE_INLINE(audioSpan, <, videoSpan) ? audioSpan : videoSpan;
                    [at insertTimeRange:CMTimeRangeMake(kCMTimeZero, span)
                                ofTrack:aTrack atTime:kCMTimeZero error:nil];
                }
                if (verr) {
                    error = verr.localizedDescription ?: [MVLang t:@"Could not read this file"];
                } else if ([NSFileManager.defaultManager fileExistsAtPath:outPath]) {
                    [NSFileManager.defaultManager removeItemAtPath:outPath error:nil];
                }
                AVAssetExportSession *export = [AVAssetExportSession
                    exportSessionWithAsset:mix presetName:AVAssetExportPresetPassthrough];
                if (!verr && !export) {
                    error = [MVLang t:@"Could not convert this file"];
                } else if (!verr) {
                    export.outputURL = [NSURL fileURLWithPath:outPath];
                    export.outputFileType = AVFileTypeMPEG4;
                    export.shouldOptimizeForNetworkUse = NO;
                    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                    __block BOOL succeeded = NO;
                    [export exportAsynchronouslyWithCompletionHandler:^{
                        succeeded = (export.status == AVAssetExportSessionStatusCompleted);
                        dispatch_semaphore_signal(sem);
                    }];
                    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600LL * NSEC_PER_SEC)));
                    if (succeeded) {
                        ok = YES;
                    } else {
                        error = [MVLang t:@"Could not convert this file"];
                    }
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok, error);
        });
    });
}

+ (void)convertToMP3:(NSString *)audioPath
                  to:(NSString *)outPath
          completion:(void (^)(BOOL, NSString *_Nullable))completion {
#if !MV_HAS_LAME
    // No encoder linked into this build; the caller keeps the original audio and
    // names the file after its real container, so nothing is mislabelled.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(NO, @"MP3 encoding is not available on this build");
    });
#else
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = NO;
        NSString *error = @"Unknown error";
        FILE *fp = NULL;
        lame_global_flags *gfp = NULL;
        AVAssetReader *reader = nil;
        AVAssetReaderTrackOutput *out = nil;
        int channels = 2;

        @autoreleasepool {
            AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:audioPath]];
            AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
            if (!track) {
                error = [MVLang t:@"Could not convert this file"];
            } else {
                reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
                NSDictionary *settings = @{
                    AVFormatIDKey: @(kAudioFormatLinearPCM),
                    AVLinearPCMBitDepthKey: @16,
                    AVLinearPCMIsFloatKey: @NO,
                    AVLinearPCMIsBigEndianKey: @NO,
                    AVLinearPCMIsNonInterleaved: @NO,
                };
                out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
                                                                outputSettings:settings];
                out.alwaysCopiesSampleData = NO;
                if (![reader canAddOutput:out]) {
                    error = [MVLang t:@"Could not convert this file"];
                } else {
                    [reader addOutput:out];
                    if (![reader startReading]) {
                        error = reader.error.localizedDescription ?: [MVLang t:@"Could not convert this file"];
                    } else {
                        CMAudioFormatDescriptionRef fmt =
                            (__bridge CMAudioFormatDescriptionRef)track.formatDescriptions.firstObject;
                        const AudioStreamBasicDescription *asbd =
                            fmt ? CMAudioFormatDescriptionGetStreamBasicDescription(fmt) : NULL;
                        long sampleRate = asbd ? (long)asbd->mSampleRate : 0;
                        if (sampleRate <= 0) sampleRate = 44100;
                        channels = (asbd && asbd->mChannelsPerFrame > 1) ? 2 : 1;

                        gfp = lame_init();
                        if (!gfp) {
                            error = [MVLang t:@"Could not convert this file"];
                        } else {
                            lame_set_num_channels(gfp, channels);
                            lame_set_in_samplerate(gfp, (int)sampleRate);
                            lame_set_brate(gfp, 192);
                            lame_set_quality(gfp, 2);
                            lame_set_mode(gfp, channels > 1 ? JOINT_STEREO : MONO);
                            if (lame_init_params(gfp) < 0) {
                                error = [MVLang t:@"Could not convert this file"];
                            } else {
                                fp = fopen(outPath.UTF8String, "wb");
                                if (!fp) {
                                    error = [MVLang t:@"Could not convert this file"];
                                } else {
                                    // LAME wants whole frames, so a buffer that is
                                    // not a multiple of the frame size is carried
                                    // over rather than dropped.
                                    const size_t frameBytes = (size_t)channels * 2;
                                    const size_t mp3Capacity = (size_t)kMaxFrames * frameBytes * 3 / 2 + 7200;
                                    NSMutableData *pending = [NSMutableData data];
                                    unsigned char *mp3buf = malloc(mp3Capacity);
                                    while (reader.status == AVAssetReaderStatusReading) {
                                        CMSampleBufferRef buf = [out copyNextSampleBuffer];
                                        if (!buf) break;
                                        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(buf);
                                        if (block) {
                                            size_t len = 0;
                                            char *bytes = NULL;
                                            if (CMBlockBufferGetDataPointer(block, 0, NULL, &len, &bytes) == kCMBlockBufferNoErr) {
                                                [pending appendBytes:bytes length:len];
                                            }
                                        }
                                        CFRelease(buf);
                                        [self drainPending:pending
                                                     toLame:gfp
                                                     output:mp3buf
                                                outCapacity:mp3Capacity
                                                       file:fp
                                                   channels:channels];
                                    }
                                    // Only a fully read track is a complete file; a
                                    // half-encoded MP3 would look like a success.
                                    if (reader.status == AVAssetReaderStatusCompleted) {
                                        [self drainPending:pending
                                                     toLame:gfp
                                                     output:mp3buf
                                                outCapacity:mp3Capacity
                                                       file:fp
                                                   channels:channels];
                                        int tail = lame_encode_flush(gfp, mp3buf, (int)mp3Capacity);
                                        if (tail > 0) fwrite(mp3buf, 1, (size_t)tail, fp);
                                        ok = YES;
                                        error = nil;
                                    } else {
                                        error = reader.error.localizedDescription ?: [MVLang t:@"Could not convert this file"];
                                    }
                                    free(mp3buf);
                                }
                            }
                        }
                    }
                }
            }
        }

        if (gfp) lame_close(gfp);
        if (fp) fclose(fp);
        if (!ok && fp) remove(outPath.UTF8String);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok, error);
        });
    });
#endif
}

#if MV_HAS_LAME
+ (void)drainPending:(NSMutableData *)pending
              toLame:(lame_global_flags *)gfp
              output:(unsigned char *)mp3buf
         outCapacity:(size_t)outCapacity
                file:(FILE *)fp
            channels:(int)channels {
    const size_t frameBytes = (size_t)channels * 2;
    while (pending.length >= frameBytes) {
        int frames = (int)(pending.length / frameBytes);
        if (frames > kMaxFrames) frames = kMaxFrames;
        size_t consumed = (size_t)frames * frameBytes;
        const short *samples = (const short *)pending.bytes;

        int wrote;
        if (channels > 1) {
            wrote = lame_encode_buffer_interleaved(gfp, (short *)samples, frames,
                                                   mp3buf, (int)outCapacity);
        } else {
            wrote = lame_encode_buffer(gfp, samples, samples, frames,
                                       mp3buf, (int)outCapacity);
        }
        if (wrote > 0) fwrite(mp3buf, 1, (size_t)wrote, fp);
        [pending replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
    }
}
#endif
@end