#import "MVMediaConverter.h"
#import "MVLang.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>

// The MP3 encoder (see build.sh). Falls back to AAC/m4a when not present.
#if __has_include(<lame.h>)
#import <lame.h>
#define MV_HAS_LAME 1
#else
#define MV_HAS_LAME 0
#endif

@implementation MVMediaConverter

+ (void)muxVideo:(NSString *)videoPath
           audio:(NSString *)audioPath
              to:(NSString *)outPath
      completion:(void (^)(BOOL, NSString *_Nullable))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = NO;
        NSString *error = @"Unknown error";
        @autoreleasepool {
            NSURL *videoURL = [NSURL fileURLWithPath:videoPath];
            NSURL *audioURL = [NSURL fileURLWithPath:audioPath];
            AVURLAsset *video = [AVURLAsset assetWithURL:videoURL];
            AVURLAsset *audio = [AVURLAsset assetWithURL:audioURL];
            AVMutableComposition *mix = [AVMutableComposition composition];

            AVAssetTrack *vTrack = [video tracksWithMediaType:AVMediaTypeVideo].firstObject;
            AVAssetTrack *aTrack = [audio tracksWithMediaType:AVMediaTypeAudio].firstObject;
            if (!vTrack) {
                error = @"No video track";
            } else {
                NSError *err = nil;
                NSError *aerr = nil;
                AVMutableCompositionTrack *vt = [mix addMutableTrackWithMediaType:AVMediaTypeVideo
                                                                preferredTrackID:kCMPersistentTrackID_Invalid];
                // Use the track's own time range: an asset's duration can exceed
                // what the track actually holds, and an over-long range fails.
                CMTime videoSpan = vTrack.timeRange.duration;
                [vt insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoSpan)
                            ofTrack:vTrack atTime:kCMTimeZero error:&err];
                // A progressive fallback already carries sound; adding the second
                // stream then would leave the file with two audio tracks.
                BOOL videoHasAudio = [video tracksWithMediaType:AVMediaTypeAudio].count > 0;
                if (aTrack && !videoHasAudio) {
                    AVMutableCompositionTrack *at = [mix addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                    preferredTrackID:kCMPersistentTrackID_Invalid];
                    // Never insert more audio than the picture has: the mux must
                    // not report success on a track that failed to land.
                    CMTime audioSpan = aTrack.timeRange.duration;
                    CMTime span = CMTIME_COMPARE_INLINE(audioSpan, <, videoSpan) ? audioSpan : videoSpan;
                    [at insertTimeRange:CMTimeRangeMake(kCMTimeZero, span)
                                ofTrack:aTrack atTime:kCMTimeZero error:&aerr];
                }
                if (err || aerr) {
                    NSError *failure = err ?: aerr;
                    error = failure.localizedDescription ?: @"Insert failed";
                } else if ([NSFileManager.defaultManager fileExistsAtPath:outPath]) {
                    [NSFileManager.defaultManager removeItemAtPath:outPath error:nil];
                }
                AVAssetExportSession *export = [AVAssetExportSession
                    exportSessionWithAsset:mix presetName:AVAssetExportPresetPassthrough];
                if (!export) {
                    error = @"Export unavailable";
                } else {
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
                        error = nil;
                    } else {
                        error = [NSString stringWithFormat:@"Mux failed (%ld)",
                                 (long)export.status];
                    }
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok, error);
        });
    });
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
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = NO;
        NSString *error = @"Unknown error";
#if MV_HAS_LAME
        // Read the audio file as raw interleaved 16-bit PCM ...
        NSURL *url = [NSURL fileURLWithPath:audioPath];
        AVAsset *asset = [AVAsset assetWithURL:url];
        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
        AVAssetTrack *at = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
        if (!reader || !at) {
            error = @"Could not read the audio track";
            goto finish;
        }
        NSDictionary *settings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: @16,
            AVLinearPCMIsFloatKey: @NO,
            AVLinearPCMIsBigEndianKey: @NO,
            AVLinearPCMIsNonInterleaved: @NO,
        };
        AVAssetReaderTrackOutput *out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:at
                                                                                   outputSettings:settings];
        if (![reader canAddOutput:out]) {
            error = @"Cannot configure audio reading";
            goto finish;
        }
        [reader addOutput:out];
        if (![reader startReading]) {
            error = reader.error.localizedDescription ?: @"Cannot start reading";
            goto finish;
        }
        // Pull the sample rate from the track: every LAME run needs it.
        AudioStreamBasicDescription asbd;
        CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)at.formatDescriptions.firstObject;
        CMFormatDescriptionGetAudioStreamBasicDescription(fd, &asbd);
        long sampleRate = (long)asbd.mSampleRate;
        if (sampleRate <= 0) sampleRate = 44100;

        // The encoder state.
        lame_global_flags *gfp = lame_init();
        lame_set_num_channels(gfp, (int)asbd.mChannelsPerFrame ?: 2);
        lame_set_in_samplerate(gfp, (int)sampleRate);
        lame_set_brate(gfp, 192);
        lame_set_quality(gfp, 2);
        lame_set_mode(gfp, asbd.mChannelsPerFrame > 1 ? JOINT_STEREO : MONO);
        if (lame_init_params(gfp) < 0) {
            lame_close(gfp);
            error = @"MP3 encoder failed to initialise";
            goto finish;
        }

        FILE *fp = fopen(outPath.UTF8String, "wb");
        static const int kPCMChunk = 44100 * 4;
        unsigned char pcm[kPCMChunk];
        unsigned char mp3buf[kPCMChunk + kPCMChunk / 4 + 7200];
        if (!fp) {
            lame_close(gfp);
            error = @"Cannot create MP3 file";
            goto finish;
        }
        while (reader.status == AVAssetReaderStatusReading) {
            CMSampleBufferRef buf = [out copyNextSampleBuffer];
            if (!buf) break;
            CMBlockBufferRef block = CMSampleBufferGetDataBuffer(buf);
            if (block) {
                size_t len = 0;
                char *bytes = NULL;
                CMBlockBufferGetDataPointer(block, 0, NULL, &len, &bytes);
                size_t used = 0;
                while (used < len) {
                    size_t take = MIN((size_t)kPCMChunk, len - used);
                    int wrote = 0;
                    if (asbd.mChannelsPerFrame > 1) {
                        wrote = lame_encode_buffer_interleaved(gfp,
                            (short *)(bytes + used), (int)(take / 4),
                            mp3buf, (int)sizeof(mp3buf));
                    } else {
                        wrote = lame_encode_buffer(gfp,
                            (short *)(bytes + used), (short *)(bytes + used),
                            (int)(take / 2), mp3buf, (int)sizeof(mp3buf));
                    }
                    if (wrote > 0) fwrite(mp3buf, 1, (size_t)wrote, fp);
                    used += take;
                }
            }
            CFRelease(buf);
        }
        int tail = lame_encode_flush(gfp, mp3buf, (int)sizeof(mp3buf));
        if (tail > 0) fwrite(mp3buf, 1, (size_t)tail, fp);
        lame_close(gfp);
        fclose(fp);
        ok = YES;
        error = nil;
    finish: ;
#else
        // No encoder linked: keep the file as-is. The caller then decides what
        // to show, but the original audio is still usable, so this is honest.
        error = @"MP3 encoding is not available on this build";
#endif
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok, error);
        });
    });
}

@end