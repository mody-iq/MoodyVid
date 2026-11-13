#import "MVDownloadEngine.h"
#import "MVPython.h"
#import "MVPaths.h"
#import "MVFileProtection.h"
#import "MVTaskStore.h"
#import "MVLang.h"
#import "MVMediaConverter.h"
#import "MVBackgroundKeeper.h"
#import "MVLog.h"
#import "MVHTTPSession.h"
#import "MVNetworkPolicy.h"
#import <Photos/Photos.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>

/// Two at a time keeps the CPU and the network busy without starving the UI
/// thread, which the Python bridge shares during the extractor phase.
static const NSUInteger kMaxConcurrent = 2;
// A delete requested while Python is unwinding must survive a process restart.
static NSString *const kPendingPythonDeletions = @"MVPendingPythonWorkDeletions";

@interface MVDownloadJob : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *quality;
@property (nonatomic, copy) NSString *runToken;
@property (nonatomic, copy, nullable) void (^completion)(NSString *, NSString *);
@end

@implementation MVDownloadJob
- (instancetype)init {
    if ((self = [super init])) _runToken = NSUUID.UUID.UUIDString;
    return self;
}
@end

@implementation MVDownloadEngine {
    NSMutableDictionary<NSString *, NSTimer *> *_pollers;
    NSMutableArray<MVDownloadJob *> *_queue;
    NSMutableDictionary<NSString *, MVDownloadJob *> *_running;
    NSMutableSet<NSString *> *_cancelled;
    NSMutableSet<NSString *> *_deleteAfterStop;
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
        _deleteAfterStop = [NSMutableSet set];
        NSArray *pending = [NSUserDefaults.standardUserDefaults arrayForKey:kPendingPythonDeletions];
        for (id identifier in pending) {
            if ([identifier isKindOfClass:NSString.class] && [identifier length]) [_deleteAfterStop addObject:identifier];
        }
        _fragments = [NSMutableDictionary dictionary];
        _backgroundTask = UIBackgroundTaskInvalid;
        // No Python worker from the previous process is alive. A still-present
        // row means the app stopped before the delete committed; keep its data.
        for (NSString *identifier in [_deleteAfterStop copy]) {
            if ([self recordFor:identifier] || [self removePythonWorkspace:identifier]) {
                [_deleteAfterStop removeObject:identifier];
            }
        }
        [self savePendingPythonDeletions];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(pump)
                                                   name:MVNetworkPolicyDidChangeNotification object:nil];
        (void)MVNetworkPolicy.shared;
    }
    return self;
}

- (NSUInteger)runningCount { return _running.count; }

#pragma mark - Thumbnails

- (void)setThumbnail:(NSString *)thumbURL forURL:(NSString *)url {
    if (!thumbURL.length || !url.length) return;
    NSURL *source = [NSURL URLWithString:thumbURL];
    if (!source) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:source cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:15];
    request.HTTPShouldHandleCookies = NO;
    [[MVHTTPSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
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
    // The store loads synchronously and changes only interrupted Active records
    // to Waiting. Do not touch Paused records or a run already in this process.
    for (MVDownloadRecord *r in MVDownloadStore.shared.records) {
        if (r.state != MVDownloadStateWaiting || _running[r.identifier]) continue;
        BOOL queued = NO;
        for (MVDownloadJob *existing in _queue) {
            if ([existing.identifier isEqualToString:r.identifier]) { queued = YES; break; }
        }
        if (queued) continue;
        MVDownloadJob *job = [MVDownloadJob new];
        job.identifier = r.identifier;
        job.url = r.url;
        job.quality = r.quality ?: @"best";
        [_queue addObject:job];
    }
    [self pump];
}

/// A resumed job must wait for its previous Python call to unwind. Jobs for the
/// same URL also wait for each other, since yt-dlp's filenames can coincide.
/// Called on the main queue, including after a network-path update.
- (void)pump {
    // A removed row must not leave an unstartable job in memory forever.
    for (MVDownloadJob *queued in [_queue copy]) {
        MVDownloadRecord *record = [self recordFor:queued.identifier];
        if (!record || record.state != MVDownloadStateWaiting) [_queue removeObject:queued];
    }
    while (MVNetworkPolicy.shared.allowsNewDownloads && _running.count < kMaxConcurrent && _queue.count) {
        NSUInteger eligible = NSNotFound;
        for (NSUInteger i = 0; i < _queue.count; i++) {
            MVDownloadJob *candidate = _queue[i];
            MVDownloadRecord *record = [self recordFor:candidate.identifier];
            if (!record || record.state != MVDownloadStateWaiting) continue;
            if (_running[candidate.identifier]) continue;
            BOOL sameURLRunning = NO;
            for (MVDownloadJob *running in _running.allValues) {
                if ([running.url isEqualToString:candidate.url]) { sameURLRunning = YES; break; }
            }
            if (!sameURLRunning) { eligible = i; break; }
        }
        if (eligible == NSNotFound) break;
        MVDownloadJob *job = _queue[eligible];
        [_queue removeObjectAtIndex:eligible];
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
    if (!record || record.state != MVDownloadStateWaiting || _running[job.identifier]) return;
    // Clear the pause only when the previous invocation has released its slot.
    [[MVPython shared] resumePausedTask:job.identifier];
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

/// Work directories are per record, not per URL or media title. Refuse a
/// redirected workspace root or an owner directory replaced with a symlink.
- (BOOL)isSafePythonWorkspace:(NSString *)workspace {
    if (!workspace.length) return NO;
    NSString *downloads = [MVPaths.downloads stringByResolvingSymlinksInPath];
    NSString *expectedParent = [downloads stringByAppendingPathComponent:@".moodyvid-work"];
    NSString *actualParent = [workspace.stringByDeletingLastPathComponent stringByResolvingSymlinksInPath];
    if (![actualParent isEqualToString:expectedParent]) return NO;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:workspace error:nil];
    return ![attrs[NSFileType] isEqual:NSFileTypeSymbolicLink];
}

- (void)savePendingPythonDeletions {
    [NSUserDefaults.standardUserDefaults setObject:_deleteAfterStop.allObjects forKey:kPendingPythonDeletions];
}

/// This is called only once the associated worker has unwound (or after launch,
/// when no prior worker exists). Never delete a workspace referenced by another
/// saved record, including records written by older versions of the app.
- (BOOL)removePythonWorkspace:(NSString *)identifier {
    NSString *workspace = [MVPaths pythonWorkDirectoryForIdentifier:identifier];
    if (![self isSafePythonWorkspace:workspace]) return NO;
    NSArray *protected = [MVFileProtection pathsExcludingTask:nil record:nil];
    return [MVFileProtection removeItemAtPath:workspace protecting:protected];
}

/// Check paths before using them as converter inputs as well as at publication.
- (BOOL)isOwnedPythonFile:(id)path identifier:(NSString *)identifier {
    if (![path isKindOfClass:NSString.class] || ![path length]) return NO;
    NSString *workspace = [MVPaths pythonWorkDirectoryForIdentifier:identifier];
    if (![self isSafePythonWorkspace:workspace] ||
        ![[path stringByDeletingLastPathComponent].stringByStandardizingPath isEqualToString:workspace.stringByStandardizingPath]) return NO;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    return [attrs[NSFileType] isEqual:NSFileTypeRegular];
}

/// Publish only this record's own regular file, after all post-processing. The
/// public name remains readable while yt-dlp's partials stay isolated on disk.
- (NSString *)publishPythonOutput:(NSString *)path forJob:(MVDownloadJob *)job {
    if (![self isOwnedPythonFile:path identifier:job.identifier]) return nil;
    NSString *name = path.lastPathComponent;
    NSString *stem = name.stringByDeletingPathExtension;
    NSString *tokenSuffix = [@"." stringByAppendingString:job.runToken];
    if ([stem hasSuffix:tokenSuffix]) {
        stem = [stem substringToIndex:stem.length - tokenSuffix.length];
        name = name.pathExtension.length ? [stem stringByAppendingPathExtension:name.pathExtension] : stem;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *destination = [MVPaths uniquePathInDirectory:MVPaths.downloads filename:name];
    return [fm moveItemAtPath:path toPath:destination error:nil] ? destination : nil;
}

/// Converter callbacks can arrive after a timeout/cancellation. Never let an old
/// exporter delete or overwrite a later run's temporary output.
- (NSString *)intermediatePath:(NSString *)proposed forJob:(MVDownloadJob *)job {
    NSString *stem = proposed.stringByDeletingPathExtension;
    NSString *unique = [stem stringByAppendingFormat:@".%@", job.runToken];
    return proposed.pathExtension.length ? [unique stringByAppendingPathExtension:proposed.pathExtension] : unique;
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

/// Removes an unsuccessful generated output unless another record owns it.
- (void)discardFragments:(NSArray<NSString *> *)paths {
    NSArray *protected = [MVFileProtection pathsExcludingTask:nil record:nil];
    for (NSString *path in paths) {
        [MVFileProtection removePartialItemAtPath:path protecting:protected];
    }
}

/// Remembers a fragment during this process so a retry can reuse it.
- (void)trackFragment:(NSString *)path forJob:(NSString *)identifier {
    if (!path.length || !identifier.length) return;
    NSMutableArray<NSString *> *list = _fragments[identifier];
    if (!list) {
        list = [NSMutableArray array];
        _fragments[identifier] = list;
    }
    [list addObject:path];
}

/// All intermediate callbacks run on the main queue. A pause or cancel can
/// arrive between Python's last progress hook and a subsequent mux/encode.
- (BOOL)jobShouldStop:(MVDownloadJob *)job {
    if (_running[job.identifier] != job || [_cancelled containsObject:job.identifier]) return YES;
    MVDownloadRecord *record = [self recordFor:job.identifier];
    return !record || record.state == MVDownloadStatePaused || record.state == MVDownloadStateCancelled ||
           [[MVPython shared] isTaskPaused:job.identifier];
}

- (void)finishStoppedJob:(MVDownloadJob *)job {
    NSString *error = [_cancelled containsObject:job.identifier] ? @"cancelled" : @"paused";
    [self finishJob:job result:nil error:error];
}

/// A fragment already downloaded for this job that is still on disk, found by
/// its `.video`/`.audio` marker. A pause keeps the fragments it has, so a resume
/// must reuse them instead of fetching the same bytes again.
- (NSString *)existingFragmentFor:(NSString *)identifier marker:(NSString *)marker {
    for (NSString *path in _fragments[identifier]) {
        if (![path.lastPathComponent containsString:marker]) continue;
        if ([self isOwnedPythonFile:path identifier:identifier]) return path;
    }
    return nil;
}

/// Two fragments then a native mux. Keeps a single record and a single progress
/// ring across the whole run: video, then audio, then the remux. A resume after
/// a pause reuses whichever fragment is already on disk.
- (void)startMergedJob:(MVDownloadJob *)job {
    MVDownloadRecord *record = [self recordFor:job.identifier];
    [self setTransient:record message:nil];

    __weak typeof(self) weakSelf = self;
    NSString *video = [self existingFragmentFor:job.identifier marker:@".video"];
    if (video.length) {
        [self continueMergedJob:job videoPath:video videoResult:nil];
        return;
    }
    // 1) Video stream only.
    [[MVPython shared] call:@"downloader" function:@"download_fragment"
                       args:@[job.url, @"video", job.quality]
                       task:job.identifier
                 completion:^(NSDictionary *videoResult, NSString *vErr) {
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        NSString *videoPath = [videoResult[@"path"] isKindOfClass:NSString.class] ? videoResult[@"path"] : nil;
        BOOL owned = [self_ isOwnedPythonFile:videoPath identifier:job.identifier];
        if (owned) [self_ trackFragment:videoPath forJob:job.identifier];
        if ([self_ jobShouldStop:job]) { [self_ finishStoppedJob:job]; return; }
        if (!owned) {
            [self_ finishJob:job result:nil error:vErr ?: [MVLang t:@"Could not read this file"]];
            return;
        }
        [self_ continueMergedJob:job videoPath:videoPath videoResult:videoResult];
    }];
}

/// The audio half of a merged job, then the mux. Split out so a resume can enter
/// here with a video fragment that is already on disk.
- (void)continueMergedJob:(MVDownloadJob *)job
                videoPath:(NSString *)videoPath
              videoResult:(NSDictionary *)videoResult {
    __weak typeof(self) weakSelf = self;
    if ([self jobShouldStop:job]) { [self finishStoppedJob:job]; return; }
    // Some sites only offer one combined file. When the picture already carries
    // its sound, the second download would fetch the same bytes again, so finish
    // here — under a clean name, without the `.video` mark.
    if ([MVMediaConverter hasAudioTrack:videoPath]) {
        NSString *ext = videoPath.pathExtension.length ? videoPath.pathExtension : @"mp4";
        NSString *proposed = [self derivedPathFor:videoPath suffix:@"" ext:ext];
        NSString *clean = [MVPaths uniquePathInDirectory:proposed.stringByDeletingLastPathComponent
                                                filename:proposed.lastPathComponent];
        if (![NSFileManager.defaultManager moveItemAtPath:videoPath toPath:clean error:nil]) {
            // A failed rename must not turn a valid combined file into a lost one.
            clean = videoPath;
            [_fragments[job.identifier] removeObject:videoPath];
        }
        NSDictionary *done = @{@"path": clean, @"title": videoResult[@"title"] ?: @"",
                               @"thumbnail": videoResult[@"thumbnail"] ?: @"",
                               @"ext": ext};
        [self finishJob:job result:done error:nil];
        return;
    }

    NSString *existingAudio = [self existingFragmentFor:job.identifier marker:@".audio"];
    if (existingAudio.length) {
        [self muxMergedJob:job videoPath:videoPath audioPath:existingAudio videoResult:videoResult];
        return;
    }

    // 2) Audio stream only.
    [[MVPython shared] call:@"downloader" function:@"download_fragment"
                       args:@[job.url, @"audio", @"best"]
                       task:job.identifier
                 completion:^(NSDictionary *audioResult, NSString *aErr) {
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        NSString *audioPath = [audioResult[@"path"] isKindOfClass:NSString.class] ? audioResult[@"path"] : nil;
        BOOL owned = [self_ isOwnedPythonFile:audioPath identifier:job.identifier];
        if (owned) [self_ trackFragment:audioPath forJob:job.identifier];
        if ([self_ jobShouldStop:job]) { [self_ finishStoppedJob:job]; return; }
        if (!owned) {
            // Keep the completed video for a later retry or resume.
            [self_ finishJob:job result:nil error:aErr ?: [MVLang t:@"Could not read this file"]];
            return;
        }
        [self_ muxMergedJob:job videoPath:videoPath audioPath:audioPath videoResult:videoResult];
    }];
}

/// The final remux of a merged job: joins the two fragments into their own name,
/// never over the video fragment.
- (void)muxMergedJob:(MVDownloadJob *)job
           videoPath:(NSString *)videoPath
           audioPath:(NSString *)audioPath
         videoResult:(NSDictionary *)videoResult {
    __weak typeof(self) weakSelf = self;
    [self setTransient:[self recordFor:job.identifier] message:[MVLang t:@"Merging…"]];
    NSString *proposed = [self derivedPathFor:videoPath suffix:@"-merged" ext:@"mp4"];
    NSString *outPath = [self intermediatePath:proposed forJob:job];
    [MVMediaConverter muxVideo:videoPath audio:audioPath to:outPath completion:^(BOOL ok, NSString *err) {
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        if ([self_ jobShouldStop:job]) {
            [self_ discardFragments:@[outPath]];
            [self_ finishStoppedJob:job];
            return;
        }
        if (ok) {
            NSDictionary *merged = @{@"path": outPath, @"title": videoResult[@"title"] ?: @"",
                                     @"thumbnail": videoResult[@"thumbnail"] ?: @"",
                                     @"ext": @"mp4"};
            [self_ finishJob:job result:merged error:nil];
        } else {
            // Drop the failed output but retain source fragments for a retry.
            [self_ discardFragments:@[outPath]];
            [self_ finishJob:job result:nil error:err ?: [MVLang t:@"Merge failed"]];
        }
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
        NSString *audioPath = [result[@"path"] isKindOfClass:NSString.class] ? result[@"path"] : nil;
        BOOL owned = [self_ isOwnedPythonFile:audioPath identifier:job.identifier];
        if (owned) [self_ trackFragment:audioPath forJob:job.identifier];
        if ([self_ jobShouldStop:job]) { [self_ finishStoppedJob:job]; return; }
        if (!owned) {
            [self_ finishJob:job result:nil error:error ?: [MVLang t:@"Could not read this file"]];
            return;
        }
        // A separate name: the encoder opens the target for writing while the
        // source is still on disk.
        NSString *proposed = [self_ derivedPathFor:audioPath suffix:@"-mp3" ext:@"mp3"];
        NSString *outPath = [self_ intermediatePath:proposed forJob:job];
        [self_ setTransient:[self_ recordFor:job.identifier] message:[MVLang t:@"Converting…"]];
        [MVMediaConverter convertToMP3:audioPath to:outPath completion:^(BOOL ok, NSString *err) {
            typeof(self) self_ = weakSelf;
            if (!self_) return;
            if ([self_ jobShouldStop:job]) {
                [self_ discardFragments:@[outPath]];
                [self_ finishStoppedJob:job];
                return;
            }
            if (ok) {
                NSDictionary *audio = @{@"path": outPath, @"title": result[@"title"] ?: @"",
                                        @"thumbnail": result[@"thumbnail"] ?: @"",
                                        @"ext": @"mp3"};
                [self_ finishJob:job result:audio error:nil];
            } else {
                // No encoder in this build: keep the original audio, drop the
                // empty target the encoder may have created.
                [self_ discardFragments:@[outPath]];
                // The original is the fallback output: forget it without deleting it.
                [self_->_fragments removeObjectForKey:job.identifier];
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
    // A paused job unwinds asynchronously, so a resume can already have queued a
    // replacement job under the same identifier. When it has, this late callback
    // belongs to a job nobody is waiting on: touching the record or the running
    // map here would clobber the live download.
    MVDownloadJob *current = _running[job.identifier];
    if (current != job) return;

    [self stopPolling:job.identifier];
    [_running removeObjectForKey:job.identifier];

    MVDownloadRecord *record = [self recordFor:job.identifier];
    void (^completion)(NSString *, NSString *) = job.completion;

    // A row may have been removed while Python or a converter was unwinding.
    // Only deletion removes its isolated workspace; never recreate the row.
    if (!record) {
        if ([_deleteAfterStop containsObject:job.identifier]) {
            if ([self removePythonWorkspace:job.identifier]) {
                [_deleteAfterStop removeObject:job.identifier];
                [self savePendingPythonDeletions];
            }
        } else if ([result[@"path"] isKindOfClass:NSString.class]) {
            // Removing history without deleting a file must not strand a late
            // completed simple download in a hidden workspace.
            [self publishPythonOutput:result[@"path"] forJob:job];
        }
        [_cancelled removeObject:job.identifier];
        [_fragments removeObjectForKey:job.identifier];
        [[MVPython shared] forgetTask:job.identifier];
        [self pump];
        return;
    }

    if ([_cancelled containsObject:job.identifier] || record.state == MVDownloadStateCancelled) {
        [_cancelled removeObject:job.identifier];
        // Cancellation alone does not mean the user asked to delete files.
        // The explicit delete action removes the workspace after the worker stops.
        [_fragments removeObjectForKey:job.identifier];
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

    // A pause unwinds the yt-dlp call (there is no way to suspend it in place),
    // so it arrives here as an error. Keep the .part file — and any fragment a
    // merged job already finished — so a resume continues instead of restarting.
    if ([error isEqualToString:@"paused"] || record.state == MVDownloadStatePaused ||
        [[MVPython shared] isTaskPaused:job.identifier]) {
        [self stopPolling:job.identifier];
        [[MVPython shared] forgetTask:job.identifier];
        // A resume can land while the aborted call is still unwinding. If the
        // record is already back in the queue, that new job owns it — putting it
        // to Paused here would show a stopped row over a running download.
        if (record.state != MVDownloadStateWaiting) {
            record.state = MVDownloadStatePaused;
            record.speed = 0;
            record.eta = 0;
            record.error = nil;
            [MVDownloadStore.shared update:record];
        }
        if (completion) completion(nil, [MVLang t:@"Paused"]);
        [self pump];
        return;
    }

    if (error) {
        MVLogError(@"engine: failed %@: %@", job.url, error);
        // A retry can reuse this record's isolated fragments and partials.
        record.state = MVDownloadStateFailed;
        record.error = error;
        [MVDownloadStore.shared update:record];
        [[MVPython shared] forgetTask:job.identifier];
        if (completion) completion(nil, error);
        [self pump];
        return;
    }

    NSString *produced = [result[@"path"] isKindOfClass:NSString.class] ? result[@"path"] : nil;
    NSString *path = produced.length ? [self publishPythonOutput:produced forJob:job] : nil;
    if (!path.length) {
        // Do not delete the workspace on publication failure: the user can retry
        // and a valid download must not be lost because its rename failed.
        record.state = MVDownloadStateFailed;
        record.error = produced.length ? [MVLang t:@"Could not save the file"] : [MVLang t:@"Unknown error"];
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
    [_fragments removeObjectForKey:job.identifier];
    [self removePythonWorkspace:job.identifier];
    [[MVPython shared] forgetTask:job.identifier];
    [self notifyFinished:record];

    // The slot is free as soon as the bytes are on disk.
    [self pump];
    if (completion) completion(path, nil);
}

- (void)cancelDownload:(NSString *)identifier {
    if (!identifier.length) return;
    MVDownloadRecord *record = [self recordFor:identifier];
    if (!record || record.state == MVDownloadStateCompleted || record.state == MVDownloadStateCancelled) return;

    MVDownloadJob *queued = nil;
    for (MVDownloadJob *job in [_queue copy]) {
        if ([job.identifier isEqualToString:identifier]) { queued = job; [_queue removeObject:job]; }
    }
    record.state = MVDownloadStateCancelled;
    record.speed = 0;
    record.eta = 0;
    record.error = nil;
    [MVDownloadStore.shared update:record];
    [self stopPolling:identifier];

    if (_running[identifier]) {
        // A queued replacement and an older unwinding call can coexist. Keep
        // the cancellation flag until that older call actually finishes.
        [_cancelled addObject:identifier];
        [[MVPython shared] cancelTask:identifier];
    } else {
        [_fragments removeObjectForKey:identifier];
        [[MVPython shared] forgetTask:identifier];
    }
    if (queued.completion) queued.completion(nil, [MVLang t:@"Cancel"]);
    [self pump];
}

- (void)removeDownload:(NSString *)identifier deleteFile:(BOOL)deleteFile {
    MVDownloadRecord *record = [self recordFor:identifier];
    if (!record) return;
    if (deleteFile) {
        [_deleteAfterStop addObject:identifier];
        [self savePendingPythonDeletions];
    }
    if (record.state != MVDownloadStateCompleted && record.state != MVDownloadStateCancelled) {
        [self cancelDownload:identifier];
    }
    if (deleteFile && record.path.length) {
        NSArray *protected = [MVFileProtection pathsExcludingTask:nil record:record];
        [MVFileProtection removeItemAtPath:record.path protecting:protected];
    }
    [MVDownloadStore.shared remove:record];
    if (deleteFile && !_running[identifier] && [self removePythonWorkspace:identifier]) {
        [_deleteAfterStop removeObject:identifier];
        [self savePendingPythonDeletions];
    }
    [self pump];
}

/// Pausing Python is cooperative: its progress hook unwinds the current call.
/// A rapid Resume can queue a replacement but cannot clear that flag early.
- (void)pauseDownload:(NSString *)identifier {
    if (!identifier.length) return;
    MVDownloadRecord *record = [self recordFor:identifier];
    if (!record || (record.state != MVDownloadStateWaiting && record.state != MVDownloadStateActive)) return;

    MVDownloadJob *queued = nil;
    for (MVDownloadJob *job in [_queue copy]) {
        if ([job.identifier isEqualToString:identifier]) { queued = job; [_queue removeObject:job]; }
    }
    if (_running[identifier]) [[MVPython shared] pauseTask:identifier];
    record.state = MVDownloadStatePaused;
    record.speed = 0;
    record.eta = 0;
    record.error = nil;
    [MVDownloadStore.shared update:record];
    [self stopPolling:identifier];
    if (queued.completion) queued.completion(nil, [MVLang t:@"Paused"]);
    [self pump];
}

/// Puts a paused or failed record back in the queue; yt-dlp may continue .part files.
- (void)resumeDownload:(NSString *)identifier {
    if (!identifier.length) return;
    MVDownloadRecord *record = [self recordFor:identifier];
    if (!record || (record.state != MVDownloadStatePaused && record.state != MVDownloadStateFailed)) return;

    record.state = MVDownloadStateWaiting;
    record.error = nil;
    [MVDownloadStore.shared update:record];

    MVDownloadJob *job = [MVDownloadJob new];
    job.identifier = identifier;
    job.url = record.url;
    job.quality = record.quality ?: @"best";
    [_queue addObject:job];
    [self pump];
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
    // A queue held for Wi-Fi (or a paused row) should not keep audio alive.
    BOOL busy = _running.count > 0;
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
        if (r.state != MVDownloadStateActive) return;
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
