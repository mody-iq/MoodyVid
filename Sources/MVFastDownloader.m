#import "MVFastDownloader.h"
#import "MVPaths.h"
#import "MVMediaProbe.h"
#import "MVLang.h"
#import "MVLog.h"
#import <UIKit/UIKit.h>

/// How many times a dropped connection is retried before its segment fails.
/// Each retry resumes from the byte offset already on disk, so it is cheap.
static const NSInteger kMaxRetries = 3;
/// The throttle wakes this often. Small enough that a large file still streams,
/// large enough that the timer costs nothing.
static const NSTimeInterval kThrottleInterval = 0.25;
/// A file smaller than this is not worth splitting: the connection overhead
/// outweighs the gain, and the progress bar would jump in ugly steps.
static const long long kMinSegmentSize = 2 * 1024 * 1024;
/// A segment must be at least this large, so a huge connection count on a small
/// file is clamped instead of producing hundreds of tiny requests.
static const long long kMinBytesPerConnection = 512 * 1024;

/// The taskDescription index that marks the size/Range probe rather than a
/// segment.
static const NSInteger kProbeIndex = -1;

/// The state of one segment file. Held per connection.
typedef NS_ENUM(NSInteger, MVSegmentState) {
    MVSegmentStateIdle = 0,
    MVSegmentStateRunning,
    MVSegmentStateDone,
};

@interface MVFastDownloader () <NSURLSessionDataDelegate>
@end

/// One piece of a multi-connection transfer. Each has its own session, its own
/// `.partN` file and its own byte range, so a stalled segment never blocks the
/// others and a resumed run continues each piece where it stopped.
@interface MVSegment : NSObject
@property (nonatomic) NSInteger index;
@property (nonatomic) long long start;        ///< inclusive
@property (nonatomic) long long end;          ///< inclusive; -1 until known
@property (nonatomic) long long written;      ///< bytes already on disk
@property (nonatomic) MVSegmentState state;
@property (nonatomic) NSInteger retries;
@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *dataTask;
@property (nonatomic, strong, nullable) NSFileHandle *handle;
@end

@implementation MVSegment
- (long long)expectedLength { return (self.end >= self.start) ? (self.end - self.start + 1) : 0; }
@end

/// One in-flight transfer: the task, its segments, and the callbacks. Held by
/// the downloader in a dictionary keyed by task identifier.
@interface MVTransfer : NSObject
@property (nonatomic, strong) MVDownloadTask *task;
@property (nonatomic, strong) NSMutableArray<MVSegment *> *segments;
@property (nonatomic) BOOL forceSingle;          ///< a 200 to a ranged segment proved it
@property (nonatomic, copy, nullable) void (^progressBlock)(MVDownloadTask *task);
@property (nonatomic, copy, nullable) void (^finishedBlock)(MVDownloadTask *task);
@property (nonatomic, copy, nullable) void (^failedBlock)(MVDownloadTask *task, NSString *message);
@property (nonatomic) long long bytesAtLastSample;
@property (nonatomic) NSTimeInterval lastSampleTime;
@property (nonatomic) NSInteger retries;        ///< retries of the whole transfer
@property (nonatomic) BOOL paused;
@property (nonatomic) BOOL cancelled;
@property (nonatomic) BOOL finishing;           ///< guards a double finish
@property (nonatomic) BOOL throttling;
@property (nonatomic, strong, nullable) NSTimer *throttleTimer;
/// The initial request that learns size/Range support before the plan is fixed.
@property (nonatomic, strong, nullable) NSURLSession *probeSession;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *probeTask;
@end

@implementation MVTransfer
- (instancetype)init {
    if ((self = [super init])) _segments = [NSMutableArray array];
    return self;
}
@end

@implementation MVFastDownloader {
    NSMutableDictionary<NSString *, MVTransfer *> *_transfers;
    dispatch_queue_t _writeQueue;
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
    transfer.lastSampleTime = NSDate.date.timeIntervalSinceNow;

    @synchronized (self) { _transfers[task.identifier] = transfer; }
    [self beginTransfer:transfer];
}

- (void)pauseTask:(MVDownloadTask *)task {
    MVTransfer *transfer = nil;
    @synchronized (self) { transfer = _transfers[task.identifier]; }
    if (!transfer) return;
    transfer.paused = YES;
    [self stopTransfer:transfer];
    @synchronized (self) { [_transfers removeObjectForKey:task.identifier]; }
    MVLogInfo(@"dl: paused %@ at %lld bytes", task.title, task.doneBytes);
}

- (void)cancelTask:(MVDownloadTask *)task {
    MVTransfer *transfer = nil;
    @synchronized (self) { transfer = _transfers[task.identifier]; }
    if (transfer) {
        transfer.cancelled = YES;
        [self stopTransfer:transfer];
        @synchronized (self) { [_transfers removeObjectForKey:task.identifier]; }
    }
    // The .part files are kept: "cancel" on an interrupted row should still leave
    // the bytes it already paid for, and the manager removes them if the user
    // really deletes the row.
}

/// Tears down every session/handle without touching the files on disk.
- (void)stopTransfer:(MVTransfer *)transfer {
    [self invalidateThrottle:transfer];
    for (MVSegment *segment in transfer.segments) [self closeSegment:segment];
    NSURLSession *probe = transfer.probeSession;
    transfer.probeSession = nil;
    transfer.probeTask = nil;
    [probe finishTasksAndInvalidate];
}

#pragma mark - Planning

/// The first request is a probe: it learns the size, whether Range works, and
/// the filename. If the server can resume and the file is big enough, the
/// transfer is then split into `connections` segments.
- (void)beginTransfer:(MVTransfer *)transfer {
    MVDownloadTask *task = transfer.task;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *headers = task.headers.count ? task.headers
            : [MVMediaProbe headersForURL:task.url referer:task.referer];
        NSMutableURLRequest *request =
            [NSMutableURLRequest requestWithURL:[NSURL URLWithString:task.url]
                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                timeoutInterval:60];
        for (NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];

        // Ask for the first byte. A 206 answers with the total size in
        // Content-Range and proves Range works; a 200 means a plain download.
        [request setValue:@"bytes=0-" forHTTPHeaderField:@"Range"];

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 60;
        config.timeoutIntervalForResource = 24 * 3600;
        config.HTTPShouldSetCookies = NO;

        NSURLSession *session = [NSURLSession sessionWithConfiguration:config
                                                             delegate:self
                                                        delegateQueue:nil];
        transfer.probeSession = session;
        NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request];
        dataTask.taskDescription = [NSString stringWithFormat:@"%@#%ld", task.identifier, (long)kProbeIndex];
        transfer.probeTask = dataTask;
        [dataTask resume];
        MVLogInfo(@"dl: probing %@ (connections %lu)", task.url, (unsigned long)task.connections);
    });
}

/// Builds the segment plan from the probed size, reusing a saved plan when one
/// exists so a relaunch keeps the same ranges.
- (void)planSegmentsFor:(MVTransfer *)transfer total:(long long)total ranges:(BOOL)ranges {
    MVDownloadTask *task = transfer.task;
    task.totalBytes = total;
    task.acceptsRanges = ranges;

    NSUInteger wanted = MAX(1, MIN(task.connections, (NSUInteger)16));
    if (transfer.forceSingle || !ranges || total <= 0 || total < kMinSegmentSize) wanted = 1;
    while (wanted > 1 && total / (long long)wanted < kMinBytesPerConnection) wanted--;

    NSMutableArray<NSArray<NSNumber *> *> *plan = [NSMutableArray array];
    if (wanted <= 1) {
        [plan addObject:@[@(0), @(total > 0 ? total - 1 : -1)]];
    } else {
        long long chunk = total / (long long)wanted;
        long long start = 0;
        for (NSUInteger i = 0; i < wanted; i++) {
            long long end = (i == wanted - 1) ? (total - 1) : (start + chunk - 1);
            [plan addObject:@[@(start), @(end)]];
            start = end + 1;
        }
    }

    // The saved plan is kept only when it is byte-for-byte the same, which is the
    // relaunch case: the part files then hold the right offsets and resume. A
    // different shape means the old pieces describe other ranges, so they must
    // go or the join would write bytes to the wrong offsets.
    if (![self plan:task.segments equals:plan]) {
        [MVFastDownloader removePartFilesForTask:task];
        task.segments = plan;
    }
    [self rebuildSegmentsFromPlan:transfer];
    [self startSegmentsFor:transfer];
}

- (BOOL)plan:(NSArray<NSArray<NSNumber *> *> *)a equals:(NSArray<NSArray<NSNumber *> *> *)b {
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) {
        if (a[i].count != 2 || b[i].count != 2) return NO;
        if (a[i][0].longLongValue != b[i][0].longLongValue) return NO;
        if (a[i][1].longLongValue != b[i][1].longLongValue) return NO;
    }
    return YES;
}

/// Recreates the in-memory segment objects from `task.segments`, reading the
/// `.partN` sizes off disk so a resume continues where it stopped.
- (void)rebuildSegmentsFromPlan:(MVTransfer *)transfer {
    [transfer.segments removeAllObjects];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSUInteger i = 0; i < transfer.task.segments.count; i++) {
        NSArray<NSNumber *> *pair = transfer.task.segments[i];
        MVSegment *segment = [MVSegment new];
        segment.index = (NSInteger)i;
        segment.start = pair[0].longLongValue;
        segment.end = pair[1].longLongValue;
        segment.state = MVSegmentStateIdle;
        NSString *path = [self segmentPathFor:transfer.task index:(NSInteger)i];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        segment.written = [attrs[NSFileSize] longLongValue];
        if (segment.written > segment.expectedLength) segment.written = 0;   // stale file
        if (segment.written >= segment.expectedLength && segment.expectedLength > 0) {
            segment.state = MVSegmentStateDone;
        }
        [transfer.segments addObject:segment];
    }
}

- (NSString *)segmentPathFor:(MVDownloadTask *)task index:(NSInteger)index {
    NSString *base = task.tempPath;
    if (!base.length) {
        NSString *directory = [MVPaths directoryForCategory:task.category];
        NSString *name = [MVPaths sanitizeFilename:task.suggestedFilename ?: task.url.lastPathComponent];
        if (!name.length) name = @"download";
        base = [directory stringByAppendingPathComponent:
                [NSString stringWithFormat:@".%@.%@.part", task.identifier, name]];
        task.tempPath = base;
    }
    return [NSString stringWithFormat:@"%@%ld", base, (long)index];
}

#pragma mark - Segments

- (void)startSegmentsFor:(MVTransfer *)transfer {
    if (transfer.paused || transfer.cancelled) return;
    for (MVSegment *segment in transfer.segments) {
        if (segment.state == MVSegmentStateDone) continue;
        if (segment.state == MVSegmentStateRunning) continue;
        [self startSegment:segment transfer:transfer];
    }
    [self recomputeProgress:transfer];
    if (self.speedLimit > 0) [self startThrottleFor:transfer];
}

- (void)startSegment:(MVSegment *)segment transfer:(MVTransfer *)transfer {
    MVDownloadTask *task = transfer.task;
    segment.state = MVSegmentStateRunning;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (transfer.paused || transfer.cancelled) return;

        NSString *path = [self segmentPathFor:task index:segment.index];
        [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        }

        NSDictionary *headers = task.headers.count ? task.headers
            : [MVMediaProbe headersForURL:task.url referer:task.referer];
        NSMutableURLRequest *request =
            [NSMutableURLRequest requestWithURL:[NSURL URLWithString:task.url]
                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                timeoutInterval:60];
        for (NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];

        long long from = segment.start + segment.written;
        long long to = segment.end;
        // "bytes=0--1" would be malformed, so an unknown end becomes an open
        // range that asks the server for the rest of the file.
        NSString *range = (to >= from) ? [NSString stringWithFormat:@"bytes=%lld-%lld", from, to]
                                       : [NSString stringWithFormat:@"bytes=%lld-", from];
        [request setValue:range forHTTPHeaderField:@"Range"];
        // If-Range: a changed file makes the server answer 200, which is detected
        // and turns the whole transfer back into a single clean download.
        if (task.etag.length) [request setValue:task.etag forHTTPHeaderField:@"If-Range"];

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 60;
        config.timeoutIntervalForResource = 24 * 3600;
        config.HTTPShouldSetCookies = NO;

        NSURLSession *session = [NSURLSession sessionWithConfiguration:config
                                                             delegate:self
                                                        delegateQueue:nil];
        segment.session = session;
        NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request];
        dataTask.taskDescription = [NSString stringWithFormat:@"%@#%ld", task.identifier, (long)segment.index];
        segment.dataTask = dataTask;
        [dataTask resume];
    });
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    MVTransfer *transfer = [self transferForTask:dataTask];
    if (!transfer) { completionHandler(NSURLSessionResponseCancel); return; }
    MVDownloadTask *task = transfer.task;
    NSInteger index = [self segmentIndexForTask:dataTask];

    if (![response isKindOfClass:NSHTTPURLResponse.class]) {
        completionHandler(NSURLSessionResponseAllow);
        return;
    }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    NSDictionary *all = http.allHeaderFields;

    if (http.statusCode >= 400) {
        completionHandler(NSURLSessionResponseCancel);
        NSString *message = [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode];
        if (index == kProbeIndex) {
            NSURLSession *probe = transfer.probeSession;
            transfer.probeSession = nil;
            transfer.probeTask = nil;
            [probe finishTasksAndInvalidate];
            dispatch_async(dispatch_get_main_queue(), ^{ [self fail:transfer message:message]; });
        } else {
            [self segmentFailedForTask:dataTask message:message];
        }
        return;
    }

    // --- Probe response: decide the plan, then start the real segments. ---
    if (index == kProbeIndex) {
        completionHandler(NSURLSessionResponseCancel);   // no body needed
        long long total = 0;
        NSString *contentRange = all[@"Content-Range"];
        if ([contentRange isKindOfClass:NSString.class]) {
            NSRange slash = [contentRange rangeOfString:@"/"];
            if (slash.location != NSNotFound) total = [contentRange substringFromIndex:NSMaxRange(slash)].longLongValue;
        }
        if (total <= 0) total = [all[@"Content-Length"] longLongValue];
        NSString *rangesHeader = all[@"Accept-Ranges"];
        BOOL ranges = (http.statusCode == 206) ||
            ([rangesHeader isKindOfClass:NSString.class] && [rangesHeader.lowercaseString containsString:@"bytes"]);
        if ([all[@"ETag"] isKindOfClass:NSString.class]) task.etag = all[@"ETag"];
        if ([all[@"Last-Modified"] isKindOfClass:NSString.class]) task.lastModified = all[@"Last-Modified"];
        [self captureFilenameFrom:all for:task];

        NSURLSession *probe = transfer.probeSession;
        transfer.probeSession = nil;
        transfer.probeTask = nil;
        [probe finishTasksAndInvalidate];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (transfer.paused || transfer.cancelled) return;
            [self planSegmentsFor:transfer total:total ranges:ranges];
        });
        return;
    }

    // --- Segment response. ---
    MVSegment *segment = [self segmentForTask:dataTask];
    if (!segment) { completionHandler(NSURLSessionResponseCancel); return; }

    // A 200 to a ranged request means the server ignored Range and is sending
    // the whole file. Drop the plan and download it as one clean stream.
    if (http.statusCode == 200 && segment.index != 0) {
        completionHandler(NSURLSessionResponseCancel);
        dispatch_async(dispatch_get_main_queue(), ^{ [self collapseToSingleConnection:transfer]; });
        return;
    }
    if (http.statusCode == 200) {
        // Even segment 0 must restart from zero in this case.
        segment.start = 0;
        segment.written = 0;
        segment.end = [all[@"Content-Length"] longLongValue] - 1;
        [self truncateSegment:segment transfer:transfer];
    }

    long long contentLength = [all[@"Content-Length"] longLongValue];
    if (http.statusCode == 206 && contentLength > 0 && segment.end < 0) {
        segment.end = segment.start + segment.written + contentLength - 1;
    }
    if ([all[@"ETag"] isKindOfClass:NSString.class]) task.etag = all[@"ETag"];
    [self openSegmentForAppend:segment transfer:transfer];

    dispatch_async(dispatch_get_main_queue(), ^{ [self recomputeProgress:transfer]; });
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    MVTransfer *transfer = [self transferForTask:dataTask];
    if (!transfer || transfer.paused || transfer.cancelled) return;
    MVSegment *segment = [self segmentForTask:dataTask];
    if (!segment) return;

    NSData *chunk = [data copy];
    @synchronized (segment) { segment.written += (long long)chunk.length; }

    dispatch_async(_writeQueue, ^{
        NSFileHandle *handle = segment.handle;
        if (!handle) return;
        @try { [handle writeData:chunk]; }
        @catch (NSException *e) { MVLogError(@"dl: write failed: %@", e.reason); }
    });

    // While throttled the timer drives progress; otherwise update on each chunk.
    // Both the byte counter and the callback live on the main queue so the
    // progress value has exactly one writer.
    if (!transfer.throttling) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (transfer.paused || transfer.cancelled) return;
            [self recomputeProgress:transfer];
            if (transfer.progressBlock) transfer.progressBlock(transfer.task);
        });
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)urlTask
didCompleteWithError:(NSError *)error {
    MVTransfer *transfer = [self transferForTask:urlTask];
    if (!transfer) return;
    if (transfer.paused || transfer.cancelled) return;
    if (error && error.code == NSURLErrorCancelled) return;

    // Probe finished with an error before it produced a plan: retry the probe.
    if ([self segmentIndexForTask:urlTask] == kProbeIndex) {
        if (error) {
            if (transfer.retries < kMaxRetries) {
                transfer.retries++;
                NSTimeInterval delay = pow(2.0, transfer.retries - 1);
                MVLogWarn(@"dl: probe retry %ld for %@ in %.0fs", (long)transfer.retries, transfer.task.title, delay);
                NSURLSession *probe = transfer.probeSession;
                transfer.probeSession = nil;
                transfer.probeTask = nil;
                [probe finishTasksAndInvalidate];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (transfer.paused || transfer.cancelled) return;
                    [self beginTransfer:transfer];
                });
            } else {
                [self fail:transfer message:error.localizedDescription ?: [MVLang t:@"Unknown error"]];
            }
        }
        return;
    }

    MVSegment *segment = [self segmentForTask:urlTask];
    if (!segment) return;
    [self closeSegment:segment];

    if (error) {
        [self segmentFailedForTask:urlTask message:error.localizedDescription ?: [MVLang t:@"Unknown error"]];
        return;
    }
    // Short read: the segment did not reach its end.
    long long written;
    @synchronized (segment) { written = segment.written; }
    if (segment.expectedLength > 0 && written < segment.expectedLength) {
        [self segmentFailedForTask:urlTask message:[MVLang t:@"Download incomplete"]];
        return;
    }
    segment.state = MVSegmentStateDone;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (transfer.paused || transfer.cancelled) return;
        [self recomputeProgress:transfer];
        BOOL allDone = YES;
        for (MVSegment *s in transfer.segments) {
            if (s.state != MVSegmentStateDone) { allDone = NO; break; }
        }
        if (allDone) [self finish:transfer];
    });
}

/// A segment error is retried in place, resuming from the bytes on disk. Only
/// when every retry is spent does the whole transfer fail.
- (void)segmentFailedForTask:(NSURLSessionTask *)urlTask message:(NSString *)message {
    MVTransfer *transfer = [self transferForTask:urlTask];
    if (!transfer || transfer.paused || transfer.cancelled) return;
    MVSegment *segment = [self segmentForTask:urlTask];
    if (!segment) return;
    [self closeSegment:segment];

    if (segment.retries < kMaxRetries) {
        segment.retries++;
        segment.state = MVSegmentStateIdle;
        NSTimeInterval delay = pow(2.0, segment.retries - 1);
        MVLogWarn(@"dl: segment %ld retry %ld in %.0fs (%@)", (long)segment.index, (long)segment.retries, delay, message);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (transfer.paused || transfer.cancelled) return;
            [self startSegment:segment transfer:transfer];
        });
        return;
    }
    [self fail:transfer message:message];
}

/// The server refused to range: throw the plan away and download as one stream.
- (void)collapseToSingleConnection:(MVTransfer *)transfer {
    if (transfer.paused || transfer.cancelled) return;
    // Several segments can report a 200 at once; only the first collapses.
    if (transfer.forceSingle) return;
    MVLogWarn(@"dl: server ignored Range for %@, single connection", transfer.task.title);
    // Do not re-probe: the server already answered a ranged request with a full
    // 200, so probing again would only repeat the same decision in a loop.
    transfer.forceSingle = YES;
    [self stopTransfer:transfer];
    // Keep .part0 (the head, which may already hold bytes) and drop the rest so
    // they cannot be mistaken for the single stream later.
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSInteger i = 1; i < 24; i++) {
        [fm removeItemAtPath:[NSString stringWithFormat:@"%@%ld", transfer.task.tempPath, (long)i] error:nil];
    }
    [self planSegmentsFor:transfer total:transfer.task.totalBytes ranges:NO];
}

#pragma mark - Progress

- (void)recomputeProgress:(MVTransfer *)transfer {
    long long done = 0, total = 0;
    for (MVSegment *segment in transfer.segments) {
        long long expected = segment.expectedLength;
        long long written;
        @synchronized (segment) { written = segment.written; }
        done += (expected > 0) ? MIN(written, expected) : written;
        total += MAX(0, expected);
    }
    transfer.task.doneBytes = done;
    if (total > 0) transfer.task.totalBytes = total;
}

#pragma mark - File handling

- (void)openSegmentForAppend:(MVSegment *)segment transfer:(MVTransfer *)transfer {
    NSString *path = [self segmentPathFor:transfer.task index:segment.index];
    dispatch_sync(_writeQueue, ^{
        segment.handle = [NSFileHandle fileHandleForWritingAtPath:path];
        [segment.handle seekToEndOfFile];
    });
}

- (void)truncateSegment:(MVSegment *)segment transfer:(MVTransfer *)transfer {
    NSString *path = [self segmentPathFor:transfer.task index:segment.index];
    [self closeSegment:segment];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
}

- (void)closeSegment:(MVSegment *)segment {
    NSURLSession *session = segment.session;
    segment.session = nil;
    segment.dataTask = nil;
    [session finishTasksAndInvalidate];
    dispatch_sync(_writeQueue, ^{
        NSFileHandle *handle = segment.handle;
        segment.handle = nil;
        if (!handle) return;
        @try { [handle synchronizeFile]; [handle closeFile]; } @catch (NSException *e) {}
    });
}

#pragma mark - Finish / fail

/// Joins the segment files into the final one, in order, streaming through a
/// buffer so a multi-gigabyte video never sits in memory.
- (void)finish:(MVTransfer *)transfer {
    if (transfer.finishing) return;
    transfer.finishing = YES;
    MVDownloadTask *task = transfer.task;

    [self invalidateThrottle:transfer];
    for (MVSegment *segment in transfer.segments) [self closeSegment:segment];

    // The join copies every byte of the file, so it runs off the main thread;
    // only the state change and the callback hop back.
    NSArray<MVSegment *> *segments = [transfer.segments copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self joinTransfer:transfer segments:segments];
    });
}

- (void)joinTransfer:(MVTransfer *)transfer segments:(NSArray<MVSegment *> *)segments {
    MVDownloadTask *task = transfer.task;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *directory = [MVPaths directoryForCategory:task.category];
    NSString *name = task.suggestedFilename.length ? task.suggestedFilename : [task.url lastPathComponent];
    NSString *final = [MVPaths uniquePathInDirectory:directory filename:name];

    BOOL ok = NO;
    if (segments.count <= 1) {
        // Single stream: just rename its one .part file.
        MVSegment *only = segments.firstObject;
        NSString *src = [self segmentPathFor:task index:(only ? only.index : 0)];
        if ([fm fileExistsAtPath:src]) {
            [fm removeItemAtPath:final error:nil];
            ok = [fm moveItemAtPath:src toPath:final error:nil];
        }
    } else {
        // Multi-segment: concatenate in order.
        [fm removeItemAtPath:final error:nil];
        [fm createFileAtPath:final contents:nil attributes:nil];
        NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:final];
        ok = (out != nil);
        for (MVSegment *segment in segments) {
            NSString *path = [self segmentPathFor:task index:segment.index];
            NSFileHandle *in = [NSFileHandle fileHandleForReadingAtPath:path];
            if (!in) { ok = NO; break; }
            @try {
                while (YES) {
                    @autoreleasepool {
                        NSData *chunk = [in readDataOfLength:1 * 1024 * 1024];
                        if (!chunk.length) break;
                        [out writeData:chunk];
                    }
                }
            } @catch (NSException *e) { ok = NO; }
            [in closeFile];
            if (!ok) break;
        }
        @try { [out synchronizeFile]; [out closeFile]; } @catch (NSException *e) {}
        if (ok) {
            // Remove the pieces only after a complete, verified join.
            for (MVSegment *segment in segments) {
                [fm removeItemAtPath:[self segmentPathFor:task index:segment.index] error:nil];
            }
        }
    }

    if (!ok) {
        // Do not leave a half-joined file at the final path: the next attempt
        // would overwrite it anyway, but a stray file confuses the user now.
        if (![fm fileExistsAtPath:task.path ?: @""]) [fm removeItemAtPath:final error:nil];
        [self fail:transfer message:[MVLang t:@"Could not save the file"]];
        return;
    }

    task.path = final;
    NSDictionary *attrs = [fm attributesOfItemAtPath:final error:nil];
    long long size = [attrs[NSFileSize] longLongValue];
    if (size > 0) task.totalBytes = size;
    task.doneBytes = task.totalBytes;
    task.speed = 0;
    task.eta = 0;
    task.tempPath = nil;
    task.segments = @[];

    @synchronized (self) { [_transfers removeObjectForKey:task.identifier]; }
    MVLogInfo(@"dl: finished %@ (%lld bytes) -> %@", task.title, task.totalBytes, final);
    // The manager mutates its store on the main queue, so the callback hops back.
    void (^finished)(MVDownloadTask *) = transfer.finishedBlock;
    dispatch_async(dispatch_get_main_queue(), ^{ if (finished) finished(task); });
}

- (void)fail:(MVTransfer *)transfer message:(NSString *)message {
    MVDownloadTask *task = transfer.task;
    [self invalidateThrottle:transfer];
    for (MVSegment *segment in transfer.segments) [self closeSegment:segment];
    NSURLSession *probe = transfer.probeSession;
    transfer.probeSession = nil;
    transfer.probeTask = nil;
    [probe finishTasksAndInvalidate];
    @synchronized (self) { [_transfers removeObjectForKey:task.identifier]; }
    MVLogError(@"dl: failed %@: %@", task.title, message);
    void (^failed)(MVDownloadTask *, NSString *) = transfer.failedBlock;
    dispatch_async(dispatch_get_main_queue(), ^{ if (failed) failed(task, message); });
}

#pragma mark - Throttle

/// A token bucket: every tick the transfer is allowed `limit * dt` bytes. When
/// the connections have already sent more than that, the sessions are suspended
/// until the next tick, which caps the average rate without dropping bytes.
- (void)startThrottleFor:(MVTransfer *)transfer {
    if (transfer.throttling) return;
    transfer.throttling = YES;
    __weak MVTransfer *weakTransfer = transfer;
    transfer.throttleTimer = [NSTimer scheduledTimerWithTimeInterval:kThrottleInterval
                                                             repeats:YES
                                                               block:^(NSTimer *timer) {
        MVTransfer *t = weakTransfer;
        if (!t || t.paused || t.cancelled) { [timer invalidate]; return; }
        [self throttleTick:t];
    }];
}

- (void)throttleTick:(MVTransfer *)transfer {
    long long limit = self.speedLimit;
    long long allowed = (long long)(limit * kThrottleInterval);
    long long delta = transfer.task.doneBytes - transfer.bytesAtLastSample;
    BOOL over = (limit > 0 && delta > allowed);
    for (MVSegment *segment in transfer.segments) {
        if (segment.state != MVSegmentStateRunning) continue;
        if (over) [segment.dataTask suspend]; else [segment.dataTask resume];
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

+ (void)removePartFilesForTask:(MVDownloadTask *)task {
    if (!task.tempPath.length) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:task.tempPath error:nil];
    // A segmented transfer uses .part0 … .partN; the count is capped at 16 in
    // the settings, so sweeping a few past that is safe and cheap.
    for (NSInteger i = 0; i < 24; i++) {
        [fm removeItemAtPath:[NSString stringWithFormat:@"%@%ld", task.tempPath, (long)i] error:nil];
    }
}

#pragma mark - Helpers

/// Delegate callbacks carry the task; its description names the transfer and
/// the segment, so the lookup is O(1) rather than a scan on every data chunk.
- (MVTransfer *)transferForTask:(NSURLSessionTask *)urlTask {
    NSString *identifier = [urlTask.taskDescription componentsSeparatedByString:@"#"].firstObject;
    if (!identifier.length) return nil;
    @synchronized (self) { return _transfers[identifier]; }
}

- (NSInteger)segmentIndexForTask:(NSURLSessionTask *)urlTask {
    NSArray<NSString *> *parts = [urlTask.taskDescription componentsSeparatedByString:@"#"];
    if (parts.count != 2) return kProbeIndex;
    return parts[1].integerValue;
}

- (MVSegment *)segmentForTask:(NSURLSessionTask *)urlTask {
    NSInteger index = [self segmentIndexForTask:urlTask];
    if (index == kProbeIndex) return nil;
    MVTransfer *transfer = [self transferForTask:urlTask];
    if (index < 0 || index >= (NSInteger)transfer.segments.count) return nil;
    return transfer.segments[(NSUInteger)index];
}

/// A filename from the server beats the URL's last path component.
- (void)captureFilenameFrom:(NSDictionary *)headers for:(MVDownloadTask *)task {
    if (task.suggestedFilename.length) return;
    NSString *disposition = headers[@"Content-Disposition"];
    if (![disposition isKindOfClass:NSString.class]) return;
    NSRange r = [disposition rangeOfString:@"filename=" options:NSCaseInsensitiveSearch];
    if (r.location == NSNotFound) return;
    NSString *name = [[disposition substringFromIndex:NSMaxRange(r)]
                      componentsSeparatedByString:@";"].firstObject;
    name = [name stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"\"' "]];
    if (name.length) task.suggestedFilename = [name stringByRemovingPercentEncoding] ?: name;
}

@end
