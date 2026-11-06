#import "MVDownloadEngine.h"
#import "MVPython.h"
#import "MVPaths.h"
#import "MVLang.h"
#import <Photos/Photos.h>

@interface MVDownloadEngine ()
- (BOOL)isVideoFile:(NSString *)path;
- (void)saveToPhotos:(NSString *)filePath completion:(void (^)(NSString *filePath, NSString *error))completion;
@end

@implementation MVDownloadEngine {
    // One timer per running download, so the UI can show live progress.
    NSMutableDictionary<NSString *, NSTimer *> *_pollers;
}

+ (instancetype)shared {
    static MVDownloadEngine *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVDownloadEngine new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) _pollers = [NSMutableDictionary dictionary];
    return self;
}

- (void)downloadURL:(NSString *)url quality:(NSString *)quality completion:(void (^)(NSString *, NSString *))completion {
    MVDownloadRecord *record = [MVDownloadStore.shared addURL:url quality:quality];
    record.state = MVDownloadStateActive;
    [MVDownloadStore.shared update:record];

    [self startPolling:record];

    [[MVPython shared] call:@"downloader" function:@"download" args:@[url, quality ?: @"best"]
                       task:record.identifier
                 completion:^(NSDictionary *result, NSString *error) {
        [self stopPolling:record.identifier];

        // A cancelled download reports back as an error; show it as cancelled.
        if ([[MVPython shared] isTaskCancelled:record.identifier]) {
            record.state = MVDownloadStateCancelled;
            record.progress = 0;
            record.speed = 0;
            record.eta = 0;
            [MVDownloadStore.shared update:record];
            [[MVPython shared] forgetTask:record.identifier];
            completion(nil, [MVLang t:@"Cancel"]);
            return;
        }

        if (error) {
            record.state = MVDownloadStateFailed;
            record.error = error;
            [MVDownloadStore.shared update:record];
            [[MVPython shared] forgetTask:record.identifier];
            completion(nil, error);
            return;
        }

        NSString *path = result[@"path"];
        if (!path.length) {
            record.state = MVDownloadStateFailed;
            record.error = [MVLang t:@"Unknown error"];
            [MVDownloadStore.shared update:record];
            [[MVPython shared] forgetTask:record.identifier];
            completion(nil, record.error);
            return;
        }

        // The engine's own metadata is better than what we had from the URL.
        NSString *title = result[@"title"];
        if ([title isKindOfClass:NSString.class] && title.length) record.title = title;
        record.path = path;
        record.progress = 1.0;
        record.speed = 0;
        record.eta = 0;
        record.totalBytes = [self fileSize:path];
        record.state = MVDownloadStateCompleted;
        [MVDownloadStore.shared update:record];
        [[MVPython shared] forgetTask:record.identifier];

        // Audio-only downloads are not videos, so Photos cannot store them.
        if ([self isVideoFile:path]) {
            [self saveToPhotos:path completion:completion];
        } else {
            completion(path, nil);
        }
    }];
}

- (void)cancelDownload:(NSString *)identifier {
    if (!identifier.length) return;
    [[MVPython shared] cancelTask:identifier];
    [self stopPolling:identifier];
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
            } else {
                // The file is on disk, so the download itself succeeded.
                completion(filePath, @"تم التحميل لكن لم يتم حفظه في الصور: الإذن مرفوض");
            }
        }];
        return;
    }
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:filePath]];
    } completionHandler:^(BOOL success, NSError *err) {
        if (success) {
            completion(filePath, nil);
        } else {
            completion(filePath, [NSString stringWithFormat:@"تم التحميل لكن فشل الحفظ في الصور: %@",
                                  err.localizedDescription ?: @"خطأ غير معروف"]);
        }
    }];
}

@end
