#import "MVFastDownloader.h"
#import "MVPaths.h"
#import "MVMediaProbe.h"
#import "MVLang.h"
#import "MVLog.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>

/// How many times a dropped connection is retried before the task fails. Each
/// retry resumes from the byte offset already on disk, so it is cheap.
static const NSInteger kMaxRetries = 3;
/// The throttle wakes this often. Small enough that a large file still streams,
/// large enough that the timer costs nothing.
static const NSTimeInterval kThrottleInterval = 0.25;

@interface MVFastDownloader () <NSURLSessionDataDelegate>
@end

/// One in-flight transfer. Held by the downloader in a dictionary keyed by task
/// identifier, and released on finish/pause/cancel.
@interface MVTransfer : NSObject
@property (nonatomic, strong) MVDownloadTask *task;
@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *dataTask;
@property (nonatomic, strong, nullable) NSFileHandle *fileHandle;
@property (nonatomic, copy, nullable) void (^progressBlock)(MVDownloadTask *task);
@property (nonatomic, copy, nullable) void (^finishedBlock)(MVDownloadTask *task);
@property (nonatomic, copy, nullable) void (^failedBlock)(MVDownloadTask *task, NSString *message);
/// Bytes seen since the last speed sample, to compute an average.
@property (nonatomic) long long bytesAtLastSample;
@property (nonatomic) NSTimeInterval lastSampleTime;
@property (nonatomic) NSTimeInterval startedAt;
@property (nonatomic) NSInteger retries;
@property (nonatomic) BOOL paused;
@property (nonatomic) BOOL cancelled;
/// Set once a throttle is applied, so the timer knows to run.
@property (nonatomic) BOOL throttling;
@property (nonatomic) NSTimer *throttleTimer;
@end

@implementation MVTransfer
@end

@implementation MVFastDownloader {
    NSMutableDictionary<NSString *, MVTransfer *> *_transfers;
    dispatch_queue_t _writeQueue;
    dispatch_queue_t _stateQueue;
    NSTimer *_tick;
}

+ (instancetype)shared {
    static MVFastDownloader *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVFastDownloader new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _transfers = [NSMutableDictionary dictionary];
        // One serial queue for all file writes: two connections must never
        // interleave writes into the same file handle.
        _writeQueue = dispatch_queue_create("com.moodyvid.dl.write", DISPATCH_QUEUE_SERIAL);
        _stateQueue = dispatch_queue_create("com.moodyvid.dl.state", DISPATCH_QUEUE_SERIAL);
        _speedLimit = 0;
    }
    return self;
}

- (BOOL)isRunningTask:(MVDownloadTask *)task {
    if (!task.identifier.length) return NO;
    @synchronized (self) {
        MVTransfer *transfer = _transfers[task.identifier];
        return transfer != nil && !transfer.paused;
    }
}

#pragma mark - Start / pause / cancel

- (void)startTask:(MVDownloadTask *)task
         progress:(void (^)(MVDownloadTask *))progress
         finished:(void (^)(MVDownloadTask *))finished
           failed:(void (^)(MVDownloadTask *, NSString *))failed {
    if (!task.url.length) {
        if (failed) failed(task, [MVLang t:@"Unknown error"]);
        return;
    }

    MVTransfer *transfer = [MVTransfer new];
    transfer.task = task;
    transfer.progressBlock = progress;
    transfer.finishedBlock = finished;
    transfer.failedBlock = failed;
    transfer.startedAt = NSDate.date.timeIntervalSinceNow;

    @synchronized (self) {
        _transfers[task.identifier] = transfer;
    }
    [self beginRequest:transfer];
}

- (void)pauseTask:(MVDownloadTask *)task {
    MVTransfer *transfer = nil;
    @synchronized (self) { transfer = _transfers[task.identifier]; }
    if (!transfer) return;
    transfer.paused = YES;
    [transfer.dataTask cancel];
    [self closeFile:transfer];
    [self invalidateThrottle:transfer];
    [self invalidateSession:transfer];
    @synchronized (self) { [_transfers removeObjectForKey:task.identifier]; }
    MVLogInfo(@"dl: paused %@ at %lld bytes", task.title, task.doneBytes);
}

- (void)cancelTask:(MVDownloadTask *)task {
    MVTransfer *transfer = nil;
    @synchronized (self) { transfer = _transfers[task.identifier]; }
    if (transfer) {
        transfer.cancelled = YES;
        [transfer.dataTask cancel];
        [self closeFile:transfer];
        [self invalidateThrottle:transfer];
        [self invalidateSession:transfer];
        @synchronized (self) { [_transfers removeObjectForKey:task.identifier]; }
    }
    // The .part file is kept: "cancel" on an interrupted row should still leave
    // the bytes it already paid for, and the manager removes them if the user
    // really deletes the row.
}

#pragma mark - Request

- (void)beginRequest:(MVTransfer *)transfer {
    MVDownloadTask *task = transfer.task;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // Build headers with the page's cookies/Referer so a signed CDN link works.
        NSDictionary *headers = task.headers.count ? task.headers
            : [MVMediaProbe headersForURL:task.url referer:task.referer];

        NSMutableURLRequest *request =
            [NSMutableURLRequest requestWithURL:[NSURL URLWithString:task.url]
                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                timeoutInterval:60];
        for (NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];

        // Resume: ask for the remainder only. A server that ignores Range
        // answers 200 with the whole file, which the delegate detects and
        // restarts cleanly.
        NSString *temp = task.tempPath;
        unsigned long long existing = 0;
        if (temp.length) {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:temp error:nil];
            existing = [attrs[NSFileSize] unsignedLongLongValue];
        }
        if (existing > 0 && task.totalBytes > 0 && existing >= (unsigned long long)task.totalBytes) {
            // Everything is already on disk; treat it as a completed transfer.
            task.doneBytes = task.totalBytes;
            dispatch_async(dispatch_get_main_queue(), ^{ [self finish:transfer]; });
            return;
        }
        if (existing > 0) {
            [request setValue:[NSString stringWithFormat:@"bytes=%llu-", existing]
           forHTTPHeaderField:@"Range"];
            // If-Range makes the server fall back to a full 200 when the file
            // changed, which the response handler detects and restarts cleanly.
            // A nil value would raise, so it is only sent when we have one.
            if (task.etag.length) [request setValue:task.etag forHTTPHeaderField:@"If-Range"];
        }
        // The file on disk is the source of truth for the resume offset, so the
        // persisted counter is corrected here rather than trusted.
        task.doneBytes = (long long)existing;
        transfer.bytesAtLastSample = (long long)existing;
        transfer.lastSampleTime = NSDate.date.timeIntervalSinceNow;

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 60;
        config.timeoutIntervalForResource = 24 * 3600;
        config.HTTPShouldSetCookies = NO;   // we set Cookie ourselves

        NSURLSession *session = [NSURLSession sessionWithConfiguration:config
                                                             delegate:self
                                                        delegateQueue:nil];
        transfer.session = session;
        NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request];
        transfer.dataTask = dataTask;
        [dataTask resume];
        MVLogInfo(@"dl: GET %@ (offset %llu, %@)", task.url, existing,
                  task.acceptsRanges ? @"ranges" : @"single");
    });
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    MVTransfer *transfer = [self transferForSession:session];
    if (!transfer) { completionHandler(NSURLSessionResponseCancel); return; }
    MVDownloadTask *task = transfer.task;

    if (![response isKindOfClass:NSHTTPURLResponse.class]) {
        completionHandler(NSURLSessionResponseAllow);
        return;
    }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    NSDictionary *all = http.allHeaderFields;

    BOOL resumed = (http.statusCode == 206);
    BOOL rangeIgnored = (http.statusCode == 200 && task.doneBytes > 0 && transfer.bytesAtLastSample > 0);

    if (http.statusCode >= 400) {
        completionHandler(NSURLSessionResponseCancel);
        NSString *message = [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode];
        dispatch_async(dispatch_get_main_queue(), ^{ [self fail:transfer message:message]; });
        return;
    }

    // A 200 to a ranged request means the server ignored Range and is about to
    // send the whole file: truncate the .part so the bytes land at offset 0.
    if (rangeIgnored || !resumed) {
        if (rangeIgnored) {
            MVLogWarn(@"dl: server ignored Range, restarting from zero: %@", task.url);
        }
        [self resetPartFile:transfer];
        task.doneBytes = 0;
    }

    long long contentLength = [all[@"Content-Length"] longLongValue];
    if (contentLength > 0) {
        task.totalBytes = resumed ? (task.doneBytes + contentLength) : contentLength;
    }
    NSString *etag = all[@"ETag"];
    if ([etag isKindOfClass:NSString.class]) task.etag = etag;
    NSString *lastModified = all[@"Last-Modified"];
    if ([lastModified isKindOfClass:NSString.class]) task.lastModified = lastModified;
    NSString *ranges = all[@"Accept-Ranges"];
    task.acceptsRanges = resumed ||
        ([ranges isKindOfClass:NSString.class] && [ranges.lowercaseString containsString:@"bytes"]);

    // A filename from the server beats the URL's last path component.
    NSString *disposition = all[@"Content-Disposition"];
    if ([disposition isKindOfClass:NSString.class] &&
        !task.suggestedFilename.length) {
        // Reuse the probe's parser indirectly: a simple filename= scan is enough.
        NSRange r = [disposition rangeOfString:@"filename=" options:NSCaseInsensitiveSearch];
        if (r.location != NSNotFound) {
            NSString *name = [[disposition substringFromIndex:NSMaxRange(r)]
                              componentsSeparatedByString:@";"].firstObject;
            name = [name stringByTrimmingCharactersInSet:
                    [NSCharacterSet characterSetWithCharactersInString:@"\"' "]];
            if (name.length) task.suggestedFilename = name.stringByRemovingPercentEncoding ?: name;
        }
    }

    // Reopen the file for appending (or create it).
    [self openFileForAppend:transfer];

    if (self.speedLimit > 0) [self startThrottleFor:transfer];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (transfer.progressBlock) transfer.progressBlock(task);
    });
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    MVTransfer *transfer = [self transferForSession:session];
    if (!transfer || transfer.paused || transfer.cancelled) return;
    MVDownloadTask *task = transfer.task;

    // Copy the buffer: NSURLSession reuses its own, and the write happens on
    // another queue.
    NSData *chunk = [data copy];
    task.doneBytes += (long long)chunk.length;

    dispatch_async(_writeQueue, ^{
        NSFileHandle *handle = transfer.fileHandle;
        if (!handle) return;
        @try {
            [handle writeData:chunk];
        } @catch (NSException *e) {
            MVLogError(@"dl: write failed for %@: %@", task.title, e.reason);
        }
    });

    if (transfer.throttling) {
        // When throttled, the throttle timer drives the progress callback so the
        // UI still updates even though chunks arrive in bursts.
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (transfer.progressBlock) transfer.progressBlock(task);
        });
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)urlTask
didCompleteWithError:(NSError *)error {
    MVTransfer *transfer = [self transferForSession:session];
    if (!transfer) return;
    MVDownloadTask *task = transfer.task;

    if (transfer.paused || transfer.cancelled) return;
    if (error && error.code == NSURLErrorCancelled) return;

    if (error) {
        // Retry with backoff, resuming from where we stopped. A task that keeps
        // failing gives up after kMaxRetries and surfaces a real message.
        if (transfer.retries < kMaxRetries) {
            transfer.retries++;
            NSTimeInterval delay = pow(2.0, transfer.retries - 1);
            MVLogWarn(@"dl: retry %ld for %@ in %.0fs (%@)", (long)transfer.retries, task.title,
                      delay, error.localizedDescription);
            [self closeFile:transfer];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (transfer.paused || transfer.cancelled) return;
                [self beginRequest:transfer];
            });
            return;
        }
        [self fail:transfer message:error.localizedDescription ?: [MVLang t:@"Unknown error"]];
        return;
    }

    // No error: verify the size when the server told us one.
    [self closeFile:transfer];
    if (task.totalBytes > 0 && task.doneBytes < task.totalBytes) {
        if (transfer.retries < kMaxRetries) {
            transfer.retries++;
            MVLogWarn(@"dl: short read (%lld/%lld), retrying %@", task.doneBytes, task.totalBytes, task.title);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (transfer.paused || transfer.cancelled) return;
                [self beginRequest:transfer];
            });
            return;
        }
        [self fail:transfer message:[MVLang t:@"Download incomplete"]];
        return;
    }

    [self finish:transfer];
}

#pragma mark - File handling

- (void)openFileForAppend:(MVTransfer *)transfer {
    MVDownloadTask *task = transfer.task;
    NSString *temp = task.tempPath;
    if (!temp.length) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:temp.stringByDeletingLastPathComponent
  withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm fileExistsAtPath:temp]) [fm createFileAtPath:temp contents:nil attributes:nil];

    dispatch_sync(_writeQueue, ^{
        transfer.fileHandle = [NSFileHandle fileHandleForWritingAtPath:temp];
        [transfer.fileHandle seekToEndOfFile];
    });
}

- (void)resetPartFile:(MVTransfer *)transfer {
    NSString *temp = transfer.task.tempPath;
    if (!temp.length) return;
    [self closeFile:transfer];
    [[NSFileManager defaultManager] removeItemAtPath:temp error:nil];
    [[NSFileManager defaultManager] createFileAtPath:temp contents:nil attributes:nil];
}

/// A session is created per transfer, so it must be torn down explicitly or its
/// connections (and the session itself) leak for the life of the app.
- (void)invalidateSession:(MVTransfer *)transfer {
    NSURLSession *session = transfer.session;
    transfer.session = nil;
    transfer.dataTask = nil;
    [session finishTasksAndInvalidate];
}

- (void)closeFile:(MVTransfer *)transfer {
    dispatch_sync(_writeQueue, ^{
        NSFileHandle *handle = transfer.fileHandle;
        transfer.fileHandle = nil;
        if (!handle) return;
        @try { [handle synchronizeFile]; [handle closeFile]; } @catch (NSException *e) {}
    });
}

#pragma mark - Finish / fail

- (void)finish:(MVTransfer *)transfer {
    MVDownloadTask *task = transfer.task;
    [self closeFile:transfer];
    [self invalidateThrottle:transfer];
    [self invalidateSession:transfer];

    // Move the .part to its final, collision-free name.
    NSString *temp = task.tempPath;
    NSString *final = task.path;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (temp.length && [fm fileExistsAtPath:temp]) {
        if (!final.length) {
            NSString *directory = [MVPaths directoryForCategory:task.category];
            NSString *name = task.suggestedFilename.length ? task.suggestedFilename
                                                           : [task.url lastPathComponent];
            final = [MVPaths uniquePathInDirectory:directory filename:name];
        }
        [fm removeItemAtPath:final error:nil];
        NSError *moveError = nil;
        if (![fm moveItemAtPath:temp toPath:final error:&moveError]) {
            MVLogError(@"dl: move failed %@ -> %@: %@", temp, final, moveError.localizedDescription);
            final = temp;   // keep the bytes, at least
        }
    }
    if (!final.length) {
        [self fail:transfer message:[MVLang t:@"Unknown error"]];
        return;
    }
    task.path = final;
    if (task.totalBytes <= 0 && final.length) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:final error:nil];
        task.totalBytes = [attrs[NSFileSize] longLongValue];
    }
    task.doneBytes = task.totalBytes > 0 ? task.totalBytes : task.doneBytes;
    task.speed = 0;
    task.eta = 0;
    task.tempPath = nil;

    @synchronized (self) { [_transfers removeObjectForKey:task.identifier]; }
    MVLogInfo(@"dl: finished %@ (%lld bytes) -> %@", task.title, task.totalBytes, final);

    if (transfer.finishedBlock) transfer.finishedBlock(task);
}

- (void)fail:(MVTransfer *)transfer message:(NSString *)message {
    MVDownloadTask *task = transfer.task;
    [self closeFile:transfer];
    [self invalidateThrottle:transfer];
    [self invalidateSession:transfer];
    @synchronized (self) { [_transfers removeObjectForKey:task.identifier]; }
    MVLogError(@"dl: failed %@: %@", task.title, message);
    if (transfer.failedBlock) transfer.failedBlock(task, message);
}

#pragma mark - Throttle

/// A token bucket: every tick the transfer is allowed `limit * dt` bytes. When
/// the connection has already sent more than that, the session is suspended
/// until the next tick, which caps the average rate without dropping bytes.
- (void)startThrottleFor:(MVTransfer *)transfer {
    if (transfer.throttling) return;
    transfer.throttling = YES;
    __weak MVTransfer *weakTransfer = transfer;
    transfer.throttleTimer = [NSTimer scheduledTimerWithTimeInterval:kThrottleInterval
                                                             repeats:YES
                                                               block:^(NSTimer *timer) {
        // The timer must not own the transfer, or the transfer could never be
        // released while a throttled download is paused.
        MVTransfer *t = weakTransfer;
        if (!t || t.paused || t.cancelled) { [timer invalidate]; return; }
        [self throttleTick:t];
    }];
}

- (void)throttleTick:(MVTransfer *)transfer {
    long long limit = self.speedLimit;
    if (limit <= 0) {
        [transfer.dataTask resume];
        return;
    }
    long long allowed = (long long)(limit * kThrottleInterval);
    long long delta = transfer.task.doneBytes - transfer.bytesAtLastSample;
    if (delta > allowed) {
        [transfer.dataTask suspend];
    } else {
        [transfer.dataTask resume];
    }
    if (delta > 0) {
        transfer.bytesAtLastSample = transfer.task.doneBytes;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (transfer.progressBlock) transfer.progressBlock(transfer.task);
        });
    }
}

- (void)invalidateThrottle:(MVTransfer *)transfer {
    [transfer.throttleTimer invalidate];
    transfer.throttleTimer = nil;
    transfer.throttling = NO;
}

#pragma mark - Helpers

- (MVTransfer *)transferForSession:(NSURLSession *)session {
    @synchronized (self) {
        for (MVTransfer *transfer in _transfers.allValues) {
            if (transfer.session == session) return transfer;
        }
    }
    return nil;
}

@end
