#import "MVDownloadEngine.h"
#import "MVPython.h"
#import "MVPaths.h"
#import "MVLang.h"
#import <Photos/Photos.h>
#import <UIKit/UIKit.h>

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

@interface MVDownloadEngine ()
- (BOOL)isVideoFile:(NSString *)path;
- (void)saveToPhotos:(NSString *)filePath completion:(void (^)(NSString *filePath, NSString *error))completion;
@end

@implementation MVDownloadEngine {
    NSMutableDictionary<NSString *, NSTimer *> *_pollers;
    NSMutableArray<MVDownloadJob *> *_queue;
    NSMutableDictionary<NSString *, MVDownloadJob *> *_running;
    NSMutableSet<NSString *> *_cancelled;
    UIBackgroundTaskIdentifier _backgroundTask;
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
        _backgroundTask = UIBackgroundTaskInvalid;
    }
    return self;
}

- (NSUInteger)runningCount { return _running.count; }

#pragma mark - Queue

- (void)downloadURL:(NSString *)url quality:(NSString *)quality completion:(void (^)(NSString *, NSString *))completion {
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

/// Starts queued jobs while there is room. Called on the main queue.
- (void)pump {
    while (_running.count < kMaxConcurrent && _queue.count) {
        MVDownloadJob *job = _queue.firstObject;
        [_queue removeObjectAtIndex:0];
        [self startJob:job];
    }
    [self updateBackgroundTask];
}

- (void)startJob:(MVDownloadJob *)job {
    MVDownloadRecord *record = [self recordFor:job.identifier];
    record.state = MVDownloadStateActive;
    [MVDownloadStore.shared update:record];

    _running[job.identifier] = job;
    [self startPolling:record];

    __weak typeof(self) weakSelf = self;
    [[MVPython shared] call:@"downloader" function:@"download" args:@[job.url, job.quality]
                       task:job.identifier
                 completion:^(NSDictionary *result, NSString *error) {
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        [self_ finishJob:job result:result error:error];
    }];
}

- (void)finishJob:(MVDownloadJob *)job result:(NSDictionary *)result error:(NSString *)error {
    [self stopPolling:job.identifier];
    [_running removeObjectForKey:job.identifier];

    MVDownloadRecord *record = [self recordFor:job.identifier];
    void (^completion)(NSString *, NSString *) = job.completion;

    if ([_cancelled containsObject:job.identifier]) {
        [_cancelled removeObject:job.identifier];
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
    record.path = path;
    record.progress = 1.0;
    record.speed = 0;
    record.eta = 0;
    record.totalBytes = [self fileSize:path];
    record.state = MVDownloadStateCompleted;
    [MVDownloadStore.shared update:record];
    [[MVPython shared] forgetTask:job.identifier];

    // The slot is free as soon as the bytes are on disk; saving to Photos is
    // slow and should not hold the queue up.
    [self pump];

    if ([self isVideoFile:path]) {
        [self saveToPhotos:path completion:completion];
    } else if (completion) {
        completion(path, nil);
    }
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
- (void)updateBackgroundTask {
    BOOL busy = _running.count > 0 || _queue.count > 0;
    if (busy && _backgroundTask == UIBackgroundTaskInvalid) {
        __weak typeof(self) weakSelf = self;
        _backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"MoodyVid downloads"
                                                                    expirationHandler:^{
            typeof(self) self_ = weakSelf;
            if (!self_) return;
            [self_ endBackgroundTask];
        }];
    } else if (!busy && _backgroundTask != UIBackgroundTaskInvalid) {
        [self endBackgroundTask];
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
                completion(filePath, @"تم التحميل لكن لم يتم حفظه في الصور: الإذن مرفوض");
            }
        }];
        return;
    }
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:filePath]];
    } completionHandler:^(BOOL success, NSError *err) {
        if (!completion) return;
        if (success) completion(filePath, nil);
        else completion(filePath, [NSString stringWithFormat:@"تم التحميل لكن فشل الحفظ في الصور: %@",
                                  err.localizedDescription ?: @"خطأ غير معروف"]);
    }];
}

@end
