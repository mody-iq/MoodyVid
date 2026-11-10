#import "MVDownloadEngine.h"
#import "MVPython.h"
#import "MVPaths.h"
#import "MVLang.h"
#import "MVMediaConverter.h"
#import "MVBackgroundKeeper.h"
#import "MVLog.h"
#import <Photos/Photos.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>

/// Two at a time keeps the CPU and the network busy without starving the UI
/// thread, which the Python bridge shares during the extractor phase.
static const NSUInteger kMaxConcurrent = 2;

@interface MVDownloadJob : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *quality;
@property (nonatomic, copy, nullable) void (^completion)(NSString *, NSString *);
@end

@implementation MVDownloadJob
@end

@implementation MVDownloadEngine {
    NSMutableDictionary<NSString *, NSTimer *> *_pollers;
    NSMutableArray<MVDownloadJob *> *_queue;
    NSMutableDictionary<NSString *, MVDownloadJob *> *_running;
    NSMutableSet<NSString *> *_cancelled;
    /// Fragment files a merged job has written so far, keyed by job id, so a
    /// cancel that lands between the two streams does not leave them orphaned.
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *_fragments;
    UIBackgroundTaskIdentifier _backgroundTask;
    BOOL _awake;
}

+ (instancetype)shared {
    static MVDownloadEngine *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVDownloadEngine new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _pollers = [NSMutableDictionary dictionary];
        _queue = [NSMutableArray array];
        _running = [NSMutableDictionary dictionary];
        _cancelled = [NSMutableSet set];
        _fragments = [NSMutableDictionary dictionary];
        _backgroundTask = UIBackgroundTaskInvalid;
    }
    return self;
}

- (NSUInteger)runningCount { return _running.count; }

#pragma mark - Thumbnails

- (void)setThumbnail:(NSString *)thumbURL forURL:(NSString *)url {
    if (!thumbURL.length || !url.length) return;
    NSURL *source = [NSURL URLWithString:thumbURL];
    if (!source) return;
    NSURLRequest *request = [NSURLRequest requestWithURL:source cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:15];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        if (err || !data.length) return;
        UIImage *image = [UIImage imageWithData:data];
        if (!image) return;
        NSString *name = [NSString stringWithFormat:@"%@.jpg",
                          [[url dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]];
        NSString *target = [[MVPaths thumbs] stringByAppendingPathComponent:name];
        NSData *jpeg = UIImageJPEGRepresentation(image, 0.7);
        if (![jpeg writeToFile:target atomically:YES]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            for (MVDownloadRecord *r in MVDownloadStore.shared.records) {
                if ([r.url isEqualToString:url] && !r.thumbnail) {
                    r.thumbnail = target;
                    [MVDownloadStore.shared update:r];
                }
            }
        });
    }] resume];
}


#pragma mark - Queue

- (void)downloadURL:(NSString *)url quality:(NSString *)quality completion:(void (^)(NSString *, NSString *))completion {
    MVLogInfo(@"engine: queue %@ (%@)", url, quality ?: @"best");
    MVDownloadRecord *record = [MVDownloadStore.shared addURL:url quality:quality];
    record.state = MVDownloadStateWaiting;
    [MVDownloadStore.shared update:record];

    MVDownloadJob *job = [MVDownloadJob new];
    job.identifier = record.identifier;
    job.url = url;
    job.quality = quality ?: @"best";
    job.completion = completion;
    [_queue addObject:job];

    [self pump];
}

- (void)resumeInterrupted {
    // Records in Waiting/Active with no process behind them came from an
    // interrupted session (a crash or the system killing us in the background).
    // Put them back in the queue; yt-dlp continues any .part files it finds.
    for (MVDownloadRecord *r in MVDownloadStore.shared.records) {
        if (r.state == MVDownloadStateWaiting || r.state == MVDownloadStateActive) {
            MVDownloadJob *job = [MVDownloadJob new];
            job.identifier = r.identifier;
            job.url = r.url;
            job.quality = r.quality ?: @"best";
            [_queue addObject:job];
            r.state = MVDownloadStateWaiting;
        }
    }
    [self pump];
}

/// Starts queued jobs while there is room. Called on the main queue.
- (void)pump {
    while (_running.count < kMaxConcurrent && _queue.count) {
        MVDownloadJob *job = _queue.firstObject;
        [_queue removeObjectAtIndex:0];
        [self startJob:job];
    }
    [self updateBackgroundTask];
}

/// True for the qualities that need a separate video + audio stream merged back
/// together. "best" and 1080p and up are usually two streams on YouTube.
+ (BOOL)isMergedQuality:(NSString *)quality {
    if (!quality.length) return NO;
    if ([quality isEqualToString:@"mp3"]) return NO;
    if ([quality isEqualToString:@"audio"]) return NO;
    if ([quality isEqualToString:@"best"]) return YES;
    NSInteger h = quality.integerValue;
    return h >= 1080;
}

/// True when the download produces a single file handled by the regular path.
+ (BOOL)isSimpleQuality:(NSString *)quality {
    return !([self isMergedQuality:quality] || [quality isEqualToString:@"mp3"]);
}

- (void)startJob:(MVDownloadJob *)job {
    MVLogInfo(@"engine: start %@ (%@)", job.url, job.quality);
    MVDownloadRecord *record = [self recordFor:job.identifier];
    record.state = MVDownloadStateActive;
    [MVDownloadStore.shared update:record];

    _running[job.identifier] = job;
    [self startPolling:record];

    if ([MVDownloadEngine isMergedQuality:job.quality]) {
        [self startMergedJob:job];
    } else if ([job.quality isEqualToString:@"mp3"]) {
        [self startAudioToMP3Job:job];
    } else {
        [self startSimpleJob:job];
    }
}

/// Single combined stream: the existing flow, unchanged.
- (void)startSimpleJob:(MVDownloadJob *)job {
    __weak typeof(self) weakSelf = self;
    [[MVPython shared] call:@"downloader" function:@"download" args:@[job.url, job.quality]
                       task:job.identifier
                 completion:^(NSDictionary *result, NSString *error) {
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        [self_ finishJob:job result:result error:error];
    }];
}

/// The path a post-download step (mux, encode) writes to. It must differ from
/// the downloaded fragment: the mux deletes its target before writing, and the
/// video fragment already ends in `.mp4`, so reusing that name destroyed the
/// source and produced an empty file.
- (NSString *)derivedPathFor:(NSString *)sourcePath suffix:(NSString *)suffix ext:(NSString *)ext {
    NSString *base = sourcePath.stringByDeletingPathExtension;
    // The fragment name carries a `.video`/`.audio` marker so the two streams
    // cannot collide; the finished file should not show it.
    for (NSString *marker in @[@".video", @".audio"]) {
        if ([base hasSuffix:marker]) {
            base = [base substringToIndex:base.length - marker.length];
            break;
        }
    }
    return [[base stringByAppendingString:suffix] stringByAppendingPathExtension:ext];
}

/// Removes leftover fragments once a merged result exists, or once a run has
/// failed or been cancelled and the fragments are of no use any more.
- (void)discardFragments:(NSArray<NSString *> *)paths {
    for (NSString *path in paths) {
        if (!path.length) continue;
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
}

/// Remembers a fragment while a merged job runs, so a cancel can clean it up.
- (void)trackFragment:(NSString *)path forJob:(NSString *)identifier {
    if (!path.length || !identifier.length) return;
    NSMutableArray<NSString *> *list = _fragments[identifier];
    if (!list) {
        list = [NSMutableArray array];
        _fragments[identifier] = list;
    }
    [list addObject:path];
}

/// Deletes every fragment still tracked for a job and forgets the job.
- (void)discardTrackedFragmentsFor:(NSString *)identifier {
    NSArray<NSString *> *paths = _fragments[identifier];
    if (paths) [self discardFragments:paths];
    [_fragments removeObjectForKey:identifier];
}

/// Two fragments then a native mux. Keeps a single record and a single progress
/// ring across the whole run: video, then audio, then the remux.
- (void)startMergedJob:(MVDownloadJob *)job {
    MVDownloadRecord *record = [self recordFor:job.identifier];
    [self setTransient:record message:nil];

    __weak typeof(self) weakSelf = self;
    // 1) Video stream only.
    [[MVPython shared] call:@"downloader" function:@"download_fragment"
                       args:@[job.url, @"video", job.quality]
                       task:job.identifier
                 completion:^(NSDictionary *videoResult, NSString *vErr) {
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        NSString *videoPath = videoResult[@"path"];
        if (!videoPath.length) {
            [self_ finishJob:job result:nil error:vErr ?: [MVLang t:@"Unknown error"]];
            return;
        }
        [self_ trackFragment:videoPath forJob:job.identifier];
        // Some sites only offer one combined file. When the picture already
        // carries its sound, the second download would fetch the same bytes
        // again, so finish here — under a clean name, without the `.video` mark.
        if ([MVMediaConverter hasAudioTrack:videoPath]) {
            NSString *clean = [self_ derivedPathFor:videoPath suffix:@"" ext:@"mp4"];
            if (![clean isEqualToString:videoPath]) {
                [[NSFileManager defaultManager] removeItemAtPath:clean error:nil];
                [[NSFileManager defaultManager] moveItemAtPath:videoPath toPath:clean error:nil];
            }
            [self_ discardTrackedFragmentsFor:job.identifier];
            NSDictionary *done = @{@"path": clean, @"title": videoResult[@"title"] ?: @"",
                                   @"thumbnail": videoResult[@"thumbnail"] ?: @"",
                                   @"ext": @"mp4"};
            [self_ finishJob:job result:done error:nil];
            return;
        }
        // 2) Audio stream only.
        [[MVPython shared] call:@"downloader" function:@"download_fragment"
                           args:@[job.url, @"audio", @"best"]
                           task:job.identifier
                     completion:^(NSDictionary *audioResult, NSString *aErr) {
            typeof(self) self_ = weakSelf;
            if (!self_) return;
            NSString *audioPath = audioResult[@"path"];
            if (!audioPath.length) {
                [self_ discardTrackedFragmentsFor:job.identifier];
                [self_ finishJob:job result:nil error:aErr ?: [MVLang t:@"Unknown error"]];
                return;
            }
            [self_ trackFragment:audioPath forJob:job.identifier];
            [self_ setTransient:[self_ recordFor:job.identifier] message:[MVLang t:@"Merging…"]];
            // 3) Native remux to its own name, never over the video fragment.
            NSString *outPath = [self_ derivedPathFor:videoPath suffix:@"-merged" ext:@"mp4"];
            [MVMediaConverter muxVideo:videoPath audio:audioPath to:outPath completion:^(BOOL ok, NSString *err) {
                typeof(self) self_ = weakSelf;
                if (!self_) return;
                if (ok) {
                    [self_ discardTrackedFragmentsFor:job.identifier];
                    NSDictionary *merged = @{@"path": outPath, @"title": videoResult[@"title"] ?: @"",
                                             @"thumbnail": videoResult[@"thumbnail"] ?: @"",
                                             @"ext": @"mp4"};
                    [self_ finishJob:job result:merged error:nil];
                } else {
                    // A half-written merged file would show up as a broken entry.
                    [self_ discardFragments:@[outPath]];
                    [self_ discardTrackedFragmentsFor:job.identifier];
                    [self_ finishJob:job result:nil error:err ?: [MVLang t:@"Merge failed"]];
                }
            }];
        }];
    }];
}

/// Downloads the best audio stream and encodes it into an MP3.
- (void)startAudioToMP3Job:(MVDownloadJob *)job {
    __weak typeof(self) weakSelf = self;
    [[MVPython shared] call:@"downloader" function:@"download_fragment"
                       args:@[job.url, @"audio", @"best"]
                       task:job.identifier
                 completion:^(NSDictionary *result, NSString *error) {
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        NSString *audioPath = result[@"path"];
        if (!audioPath.length) {
            [self_ finishJob:job result:nil error:error ?: [MVLang t:@"Unknown error"]];
            return;
        }
        [self_ trackFragment:audioPath forJob:job.identifier];
        // A separate name: the encoder opens the target for writing while the
        // source is still on disk.
        NSString *outPath = [self_ derivedPathFor:audioPath suffix:@"-mp3" ext:@"mp3"];
        [self_ setTransient:[self_ recordFor:job.identifier] message:[MVLang t:@"Converting…"]];
        [MVMediaConverter convertToMP3:audioPath to:outPath completion:^(BOOL ok, NSString *err) {
            typeof(self) self_ = weakSelf;
            if (!self_) return;
            if (ok) {
                [self_ discardTrackedFragmentsFor:job.identifier];
                NSDictionary *audio = @{@"path": outPath, @"title": result[@"title"] ?: @"",
                                        @"thumbnail": result[@"thumbnail"] ?: @"",
                                        @"ext": @"mp3"};
                [self_ finishJob:job result:audio error:nil];
            } else {
                // No encoder in this build: keep the original audio, drop the
                // empty target the encoder may have created.
                [self_ discardFragments:@[outPath]];
                [self_ discardTrackedFragmentsFor:job.identifier];
                NSDictionary *audio = @{@"path": audioPath, @"title": result[@"title"] ?: @"",
                                        @"thumbnail": result[@"thumbnail"] ?: @"",
                                        @"ext": audioPath.pathExtension.lowercaseString ?: @"m4a"};
                [self_ finishJob:job result:audio error:nil];
            }
        }];
    }];
}

/// Stores a transient status message the row shows while a post-download step
/// (mux, encode) runs. The `error` field is cleared when the job completes.
- (void)setTransient:(MVDownloadRecord *)record message:(NSString * _Nullable)message {
    if (!record) return;
    record.error = message;
    [MVDownloadStore.shared update:record];
}

- (void)finishJob:(MVDownloadJob *)job result:(NSDictionary *)result error:(NSString *)error {
    [self stopPolling:job.identifier];
    [_running removeObjectForKey:job.identifier];

    MVDownloadRecord *record = [self recordFor:job.identifier];
    void (^completion)(NSString *, NSString *) = job.completion;

    if ([_cancelled containsObject:job.identifier]) {
        [_cancelled removeObject:job.identifier];
        // A cancel can land after the mux produced a file; drop every artefact.
        NSString *produced = result[@"path"];
        if (produced.length) [self discardFragments:@[produced]];
        [self discardTrackedFragmentsFor:job.identifier];
        record.state = MVDownloadStateCancelled;
        record.progress = 0;
        record.speed = 0;
        record.eta = 0;
        [MVDownloadStore.shared update:record];
        [[MVPython shared] forgetTask:job.identifier];
        if (completion) completion(nil, [MVLang t:@"Cancel"]);
        [self pump];
        return;
    }

    if (error) {
        MVLogError(@"engine: failed %@: %@", job.url, error);
        [self discardTrackedFragmentsFor:job.identifier];
        record.state = MVDownloadStateFailed;
        record.error = error;
        [MVDownloadStore.shared update:record];
        [[MVPython shared] forgetTask:job.identifier];
        if (completion) completion(nil, error);
        [self pump];
        return;
    }

    NSString *path = result[@"path"];
    if (!path.length) {
        [self discardTrackedFragmentsFor:job.identifier];
        record.state = MVDownloadStateFailed;
        record.error = [MVLang t:@"Unknown error"];
        [MVDownloadStore.shared update:record];
        [[MVPython shared] forgetTask:job.identifier];
        if (completion) completion(nil, record.error);
        [self pump];
        return;
    }

    // The engine's own metadata beats what we had from the URL.
    NSString *title = result[@"title"];
    if ([title isKindOfClass:NSString.class] && title.length) record.title = title;
    NSString *thumb = result[@"thumbnail"];
    if ([thumb isKindOfClass:NSString.class] && thumb.length && record.url.length) {
        [self setThumbnail:thumb forURL:record.url];
    }
    // The yt-dlp covers are web shots; the local frame keeps the row looking
    // like a real video library and works when the cover fetch fails.
    [self makeVideoThumb:path forURL:record.url];
    record.path = path;
    record.progress = 1.0;
    record.speed = 0;
    record.eta = 0;
    record.error = nil;  // drop the transient "Merging…"/"Converting…" phase text
    record.totalBytes = [self fileSize:path];
    record.state = MVDownloadStateCompleted;
    MVLogInfo(@"engine: done %@ -> %@", job.url, path);
    [MVDownloadStore.shared update:record];
    [[MVPython shared] forgetTask:job.identifier];
    [self notifyFinished:record];

    // The slot is free as soon as the bytes are on disk.
    [self pump];
    if (completion) completion(path, nil);
}

- (void)cancelDownload:(NSString *)identifier {
    if (!identifier.length) return;
    [_cancelled addObject:identifier];
    [[MVPython shared] cancelTask:identifier];

    // Still queued: drop it now, there is nothing running to abort.
    for (MVDownloadJob *job in [_queue copy]) {
        if ([job.identifier isEqualToString:identifier]) {
            [_queue removeObject:job];
            MVDownloadRecord *record = [self recordFor:identifier];
            record.state = MVDownloadStateCancelled;
            [MVDownloadStore.shared update:record];
            [_cancelled removeObject:identifier];
            if (job.completion) job.completion(nil, [MVLang t:@"Cancel"]);
            [self updateBackgroundTask];
            break;
        }
    }
    [self stopPolling:identifier];
}

- (MVDownloadRecord *)recordFor:(NSString *)identifier {
    for (MVDownloadRecord *r in MVDownloadStore.shared.records) {
        if ([r.identifier isEqualToString:identifier]) return r;
    }
    return nil;
}

#pragma mark - Background time

/// While anything is queued or running, hold one background task assertion.
/// Without it iOS suspends the process a few seconds after the app leaves the
/// foreground and the download stops mid-file.
///
/// The task assertion is only good for a few minutes, so it is paired with a
/// silent-audio keep-alive that holds the process for as long as the queue runs.
- (void)updateBackgroundTask {
    BOOL busy = _running.count > 0 || _queue.count > 0;
    if (busy) {
        if (!_awake) {
            _awake = YES;
            [[MVBackgroundKeeper shared] begin];
        }
        if (_backgroundTask == UIBackgroundTaskInvalid) {
            __weak typeof(self) weakSelf = self;
            _backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"MoodyVid downloads"
                                                                        expirationHandler:^{
                typeof(self) self_ = weakSelf;
                if (!self_) return;
                [self_ endBackgroundTask];
            }];
        }
    } else {
        if (_awake) {
            _awake = NO;
            [[MVBackgroundKeeper shared] end];
        }
        if (_backgroundTask != UIBackgroundTaskInvalid) [self endBackgroundTask];
    }
}

- (void)endBackgroundTask {
    if (_backgroundTask == UIBackgroundTaskInvalid) return;
    [UIApplication.sharedApplication endBackgroundTask:_backgroundTask];
    _backgroundTask = UIBackgroundTaskInvalid;
}

#pragma mark - Progress

- (void)startPolling:(MVDownloadRecord *)record {
    // Python cannot call back into the UI safely, so it stores progress and we
    // read it on a timer. 4 Hz looks smooth without wasting battery.
    __weak MVDownloadRecord *weakRecord = record;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
        MVDownloadRecord *r = weakRecord;
        if (!r) { [t invalidate]; return; }
        NSDictionary *p = [[MVPython shared] progressForTask:r.identifier];
        if (!p.count) return;

        id status = p[@"status"];
        if ([status isKindOfClass:NSString.class] && [status isEqualToString:@"finished"]) r.progress = 1.0;
        id progress = p[@"progress"];
        if ([progress respondsToSelector:@selector(doubleValue)]) {
            double v = [progress doubleValue];
            if (v >= 0) r.progress = v;
        }
        id speed = p[@"speed"];
        if ([speed respondsToSelector:@selector(doubleValue)]) r.speed = [speed doubleValue];
        id eta = p[@"eta"];
        if ([eta respondsToSelector:@selector(doubleValue)]) r.eta = [eta doubleValue];
        id total = p[@"total"];
        if ([total respondsToSelector:@selector(longLongValue)]) r.totalBytes = [total longLongValue];

        // The real title arrives once the extractor has resolved the video.
        NSString *title = p[@"title"];
        if ([title isKindOfClass:NSString.class] && title.length) r.title = title;

        [MVDownloadStore.shared update:r];
    }];
    _pollers[record.identifier] = timer;
}

- (void)stopPolling:(NSString *)identifier {
    NSTimer *timer = _pollers[identifier];
    if (timer) {
        [timer invalidate];
        [_pollers removeObjectForKey:identifier];
    }
}

- (long long)fileSize:(NSString *)path {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    return [attrs[NSFileSize] longLongValue];
}

#pragma mark - Notifications

/// A banner is the only signal the user gets when a download finishes while they
/// are on another tab or in another app.
- (void)notifyFinished:(MVDownloadRecord *)record {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = [MVLang t:@"Downloaded successfully"];
    content.body = record.title.length ? record.title : record.url;
    content.sound = nil;   // Downloading is not urgent enough to interrupt audio.

    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:record.identifier
                                                                         content:content
                                                                         trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
}

#pragma mark - Photos

- (BOOL)isVideoFile:(NSString *)path {
    static NSSet *extensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        extensions = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"webm", @"mkv", @"avi", @"3gp"]];
    });
    return [extensions containsObject:path.pathExtension.lowercaseString];
}

- (void)saveToPhotos:(NSString *)filePath completion:(void (^)(NSString *, NSString *))completion {
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
    if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus newStatus) {
            if (newStatus == PHAuthorizationStatusAuthorized || newStatus == PHAuthorizationStatusLimited) {
                [self saveToPhotos:filePath completion:completion];
            } else if (completion) {
                // The file is on disk, so the download itself succeeded.
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(filePath, [MVLang t:@"Saved to Files but not to Photos: permission denied"]);
                });
            }
        }];
        return;
    }
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:filePath]];
    } completionHandler:^(BOOL success, NSError *err) {
        // This completion arrives on a Photos-library queue; anyone showing an
        // alert reads the result, so marshal it back to the main queue first.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!completion) return;
            if (success) completion(filePath, nil);
            else completion(filePath, [NSString stringWithFormat:@"%@: %@",
                                      [MVLang t:@"Saved to Files but not to Photos"],
                                      err.localizedDescription ?: [MVLang t:@"Unknown error"]]);
        });
    }];
}


/// Writes a square frame from the video itself (like the row artwork in the
/// Downloads list). AVAssetImageGenerator is thread-safe and fast enough to run
/// on a background queue; the URL and record are looked up again on the main
/// thread so stale objects are never touched.
- (void)makeVideoThumb:(NSString *)path forURL:(NSString *)url {
    if (!path.length || !url.length) return;
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    AVURLAsset *asset = [AVURLAsset assetWithURL:fileURL];
    AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.maximumSize = CGSizeMake(360, 360);
    // yt-dlp output has no duration metadata until the file is fully written by
    // the time we get here it is, but a zero-time frame is the safe pick.
    CMTime at = CMTimeMakeWithSeconds(1, 600);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *err = nil;
        CGImageRef cg = [gen copyCGImageAtTime:at actualTime:NULL error:&err];
        if (err || !cg) return;
        UIImage *full = [UIImage imageWithCGImage:cg];
        CGImageRelease(cg);
        // Square crop from the top; avatars in the list are square.
        CGFloat side = MIN(full.size.width, full.size.height);
        CGRect crop = CGRectMake((full.size.width - side) / 2, 0, side, side);
        CGImageRef ccg = CGImageCreateWithImageInRect(full.CGImage, crop);
        if (!ccg) return;
        UIImage *square = [UIImage imageWithCGImage:ccg];
        CGImageRelease(ccg);
        NSData *jpeg = UIImageJPEGRepresentation(square, 0.85);
        if (!jpeg.length) return;

        NSString *name = [NSString stringWithFormat:@"%@-local.jpg",
                          [[url dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]];
        NSString *target = [[MVPaths thumbs] stringByAppendingPathComponent:name];
        [jpeg writeToFile:target atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            for (MVDownloadRecord *r in MVDownloadStore.shared.records) {
                if ([r.url isEqualToString:url] && !r.thumbnail) {
                    r.thumbnail = target;
                    [MVDownloadStore.shared update:r];
                }
            }
        });
    });
}

@end
