#import "MVHLSDownloader.h"
#import "MVPaths.h"
#import "MVMediaProbe.h"
#import "MVLang.h"
#import "MVLog.h"
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonCryptor.h>

/// How many media segments are fetched at once. Segments are small and
/// independent, so a few in flight is the difference between a stream that
/// downloads at line speed and one that crawls one request at a time.
static const NSInteger kMaxParallelSegments = 4;
/// Retries per segment before the whole task fails.
static const NSInteger kMaxSegmentRetries = 3;

/// One encryption key from an `#EXT-X-KEY` tag.
@interface MVHLSKey : NSObject
@property (nonatomic, copy) NSString *method;      ///< NONE, AES-128, SAMPLE-AES
@property (nonatomic, copy, nullable) NSString *uri;
@property (nonatomic, strong, nullable) NSData *iv;
@property (nonatomic, strong, nullable) NSData *data;   ///< the fetched key bytes
@end
@implementation MVHLSKey
@end

/// One media segment: where to get it, how to decrypt it, and whether it landed.
@interface MVHLSSegment : NSObject
@property (nonatomic) NSInteger index;
@property (nonatomic, copy) NSString *url;
@property (nonatomic) long long byteStart;    ///< -1 when the whole resource
@property (nonatomic) long long byteLength;   ///< -1 when the whole resource
@property (nonatomic, strong, nullable) MVHLSKey *key;
/// The HLS media sequence number, used as the AES IV when the key has none.
@property (nonatomic) NSInteger sequence;
@property (nonatomic) NSInteger retries;
@property (nonatomic) BOOL done;
@end
@implementation MVHLSSegment
@end

/// One running HLS download.
@interface MVHLSJob : NSObject
@property (nonatomic, strong) MVDownloadTask *task;
@property (nonatomic, strong) NSMutableArray<MVHLSSegment *> *segments;
/// The fMP4 init segment (EXT-X-MAP), if the playlist names one.
@property (nonatomic, strong, nullable) MVHLSSegment *initSegment;
@property (nonatomic) BOOL isFMP4;
@property (nonatomic) BOOL paused;
@property (nonatomic) BOOL cancelled;
@property (nonatomic) BOOL finishing;
@property (nonatomic) NSUInteger inFlight;
@property (nonatomic) long long doneBytes;
@property (nonatomic, copy, nullable) void (^progressBlock)(MVDownloadTask *task);
@property (nonatomic, copy, nullable) void (^finishedBlock)(MVDownloadTask *task);
@property (nonatomic, copy, nullable) void (^failedBlock)(MVDownloadTask *task, NSString *message);
@end
@implementation MVHLSJob
- (instancetype)init {
    if ((self = [super init])) _segments = [NSMutableArray array];
    return self;
}
@end

@implementation MVHLSDownloader {
    NSMutableDictionary<NSString *, MVHLSJob *> *_jobs;
}

+ (instancetype)shared {
    static MVHLSDownloader *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVHLSDownloader new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _jobs = [NSMutableDictionary dictionary];
        _speedLimit = 0;
    }
    return self;
}

- (BOOL)isRunningTask:(MVDownloadTask *)task {
    if (!task.identifier.length) return NO;
    @synchronized (self) {
        MVHLSJob *job = _jobs[task.identifier];
        return job != nil && !job.paused;
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
    MVHLSJob *job = [MVHLSJob new];
    job.task = task;
    job.progressBlock = progress;
    job.finishedBlock = finished;
    job.failedBlock = failed;
    @synchronized (self) { _jobs[task.identifier] = job; }
    [self fetchPlaylistForJob:job];
}

- (void)pauseTask:(MVDownloadTask *)task {
    MVHLSJob *job = nil;
    @synchronized (self) { job = _jobs[task.identifier]; }
    if (!job) return;
    job.paused = YES;
    @synchronized (self) { [_jobs removeObjectForKey:task.identifier]; }
    MVLogInfo(@"hls: paused %@ at %lld bytes", task.title, job.doneBytes);
}

- (void)cancelTask:(MVDownloadTask *)task {
    MVHLSJob *job = nil;
    @synchronized (self) { job = _jobs[task.identifier]; }
    if (!job) return;
    job.cancelled = YES;
    @synchronized (self) { [_jobs removeObjectForKey:task.identifier]; }
}

#pragma mark - Playlist

- (void)fetchPlaylistForJob:(MVHLSJob *)job {
    NSString *url = job.task.url;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *headers = [MVMediaProbe headersForURL:url referer:job.task.referer];
        NSError *error = nil;
        NSData *data = [self syncGet:url headers:headers error:&error];
        if (!data) {
            [self failJob:job message:error.localizedDescription ?: [MVLang t:@"Could not open the stream"]];
            return;
        }
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text.length) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        if (![text containsString:@"#EXTM3U"]) {
            [self failJob:job message:[MVLang t:@"Could not open the stream"]];
            return;
        }

        // A master playlist points at a variant; a media playlist lists segments.
        NSString *variant = [self firstVariantInPlaylist:text baseURL:url];
        if (variant) {
            NSError *verror = nil;
            NSData *vdata = [self syncGet:variant headers:headers error:&verror];
            NSString *vtext = vdata ? [[NSString alloc] initWithData:vdata encoding:NSUTF8StringEncoding] : nil;
            if (!vtext.length) {
                [self failJob:job message:verror.localizedDescription ?: [MVLang t:@"Could not open the stream"]];
                return;
            }
            [self parseMediaPlaylist:vtext baseURL:variant into:job];
        } else {
            [self parseMediaPlaylist:text baseURL:url into:job];
        }

        if (!job.segments.count) {
            [self failJob:job message:[MVLang t:@"Could not open the stream"]];
            return;
        }

        // An fMP4 stream begins with an init segment; it must be written first
        // so the joined file starts with the moov box the media needs.
        if (job.initSegment) {
            NSError *initError = nil;
            NSData *initData = [self syncGet:job.initSegment.url
                                     headers:[MVMediaProbe headersForURL:job.initSegment.url
                                                                 referer:job.task.referer]
                                       error:&initError];
            if (!initData.length) {
                [self failJob:job message:[MVLang t:@"Could not open the stream"]];
                return;
            }
            [self writeSegment:initData index:-1 job:job];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (job.paused || job.cancelled) return;
            job.task.phase = [MVLang t:@"Downloading segments"];
            [self pumpJob:job];
        });
    });
}

/// The first `#EXT-X-STREAM-INF` variant URL, resolved against the playlist.
- (NSString *)firstVariantInPlaylist:(NSString *)text baseURL:(NSString *)base {
    __block BOOL sawStreamInf = NO;
    __block NSString *found = nil;
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([trimmed hasPrefix:@"#EXT-X-STREAM-INF"]) { sawStreamInf = YES; return; }
        if (sawStreamInf && trimmed.length && ![trimmed hasPrefix:@"#"]) {
            found = [self absoluteURL:trimmed base:base];
            *stop = YES;
        }
    }];
    return found;
}

- (void)parseMediaPlaylist:(NSString *)text baseURL:(NSString *)base into:(MVHLSJob *)job {
    __block MVHLSKey *currentKey = nil;
    __block long long nextByteOffset = 0;
    __block BOOL hasPendingByteRange = NO;
    __block NSInteger index = 0;
    __block BOOL hasEndList = NO;
    __block NSString *mapURL = nil;
    __block NSInteger mediaSequence = 0;

    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!trimmed.length) return;

        if ([trimmed hasPrefix:@"#EXT-X-ENDLIST"]) { hasEndList = YES; return; }

        if ([trimmed hasPrefix:@"#EXT-X-MEDIA-SEQUENCE"]) {
            mediaSequence = (NSInteger)[[[trimmed componentsSeparatedByString:@":"] lastObject] integerValue];
            return;
        }

        if ([trimmed hasPrefix:@"#EXT-X-MAP"]) {
            NSString *uri = [self attribute:@"URI" in:trimmed];
            if (uri.length) mapURL = [self absoluteURL:uri base:base];
            return;
        }

        if ([trimmed hasPrefix:@"#EXT-X-KEY"]) {
            NSString *method = [self attribute:@"METHOD" in:trimmed] ?: @"NONE";
            MVHLSKey *key = [MVHLSKey new];
            key.method = method;
            if (![method isEqualToString:@"NONE"]) {
                NSString *uri = [self attribute:@"URI" in:trimmed];
                if (uri.length) key.uri = [self absoluteURL:uri base:base];
                NSString *iv = [self attribute:@"IV" in:trimmed];
                if (iv.length) key.iv = [self dataFromHexIV:iv];
            }
            currentKey = key;
            return;
        }

        if ([trimmed hasPrefix:@"#EXT-X-BYTERANGE"]) {
            // "LENGTH[@OFFSET]" — a missing offset continues after the last
            // sub-range, which is the common "one resource, many ranges" form.
            NSString *value = [[trimmed componentsSeparatedByString:@":"] lastObject];
            NSArray<NSString *> *parts = [value componentsSeparatedByString:@"@"];
            long long length = [parts.firstObject longLongValue];
            long long start = parts.count > 1 ? [parts[1] longLongValue] : nextByteOffset;
            nextByteOffset = start + length;
            hasPendingByteRange = YES;
            // The range applies to the next segment URI.
            MVHLSSegment *segment = [MVHLSSegment new];
            segment.index = index++;
            segment.sequence = mediaSequence + segment.index;
            segment.byteStart = start;
            segment.byteLength = length;
            segment.key = currentKey;
            segment.url = @"";   // filled when the URI line arrives
            [job.segments addObject:segment];
            return;
        }

        if ([trimmed hasPrefix:@"#"]) return;

        NSString *absolute = [self absoluteURL:trimmed base:base];
        if (hasPendingByteRange && job.segments.count &&
            ![job.segments.lastObject.url length]) {
            // The URI belongs to the byterange declared just above it.
            job.segments.lastObject.url = absolute;
            hasPendingByteRange = NO;
        } else {
            MVHLSSegment *segment = [MVHLSSegment new];
            segment.index = index++;
            segment.sequence = mediaSequence + segment.index;
            segment.byteStart = -1;
            segment.byteLength = -1;
            segment.key = currentKey;
            segment.url = absolute;
            [job.segments addObject:segment];
        }
    }];

    if (!hasEndList) {
        // A live playlist has no end, so it can never be "finished" as a file.
        job.task.phase = nil;
        [self failJob:job message:[MVLang t:@"Live streams can't be downloaded"]];
        return;
    }
    if (mapURL.length) {
        MVHLSSegment *init = [MVHLSSegment new];
        init.index = -1;
        init.url = mapURL;
        init.byteStart = -1;
        init.byteLength = -1;
        init.key = nil;
        job.initSegment = init;
        job.isFMP4 = YES;
    }
    // Drop any segment whose URI line never arrived (malformed playlist).
    [job.segments filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(MVHLSSegment *s, NSDictionary *bindings) {
        return s.url.length > 0;
    }]];

    // Fetch each distinct key once, up front, so a segment never has to wait on
    // a key request mid-download.
    NSMutableDictionary<NSString *, MVHLSKey *> *byURI = [NSMutableDictionary dictionary];
    for (MVHLSSegment *segment in job.segments) {
        MVHLSKey *key = segment.key;
        if (!key || [key.method isEqualToString:@"NONE"] || !key.uri.length) continue;
        if ([key.method isEqualToString:@"SAMPLE-AES"]) {
            job.task.phase = nil;
            [self failJob:job message:[MVLang t:@"This stream is protected and can't be downloaded"]];
            return;
        }
        MVHLSKey *existing = byURI[key.uri];
        if (existing) { segment.key = existing; continue; }
        NSError *keyError = nil;
        NSData *keyData = [self syncGet:key.uri
                                headers:[MVMediaProbe headersForURL:key.uri referer:job.task.referer]
                                  error:&keyError];
        if (!keyData.length) {
            job.task.phase = nil;
            [self failJob:job message:[MVLang t:@"Could not open the stream"]];
            return;
        }
        key.data = keyData;
        byURI[key.uri] = key;
    }
}

#pragma mark - Segments

- (void)pumpJob:(MVHLSJob *)job {
    if (job.paused || job.cancelled || job.finishing) return;
    while (job.inFlight < (NSUInteger)kMaxParallelSegments) {
        MVHLSSegment *next = nil;
        for (MVHLSSegment *segment in job.segments) {
            if (!segment.done && segment.retries < kMaxSegmentRetries) { next = segment; break; }
        }
        if (!next) break;
        [self fetchSegment:next job:job];
    }
    if (job.inFlight > 0) return;
    BOOL pending = NO;
    for (MVHLSSegment *segment in job.segments) {
        if (segment.done) continue;
        if (segment.retries >= kMaxSegmentRetries) {
            // A segment that used up its retries cannot be recovered, and
            // joining without it would produce a corrupt file.
            [self failJob:job message:[MVLang t:@"Download incomplete"]];
            return;
        }
        pending = YES;
    }
    if (!pending) [self finishJob:job];
}

- (void)fetchSegment:(MVHLSSegment *)segment job:(MVHLSJob *)job {
    job.inFlight++;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (job.paused || job.cancelled) { dispatch_async(dispatch_get_main_queue(), ^{ job.inFlight--; }); return; }
        NSDictionary *headers = [MVMediaProbe headersForURL:segment.url referer:job.task.referer];
        if (segment.byteStart >= 0) {
            NSMutableDictionary *mutable = [headers mutableCopy];
            mutable[@"Range"] = [NSString stringWithFormat:@"bytes=%lld-%lld",
                                 segment.byteStart, segment.byteStart + segment.byteLength - 1];
            headers = mutable;
        }
        NSError *error = nil;
        NSData *data = [self syncGet:segment.url headers:headers error:&error];
        if (data && segment.key.data && [segment.key.method isEqualToString:@"AES-128"]) {
            data = [self decrypt:data key:segment.key.data iv:segment.key.iv sequence:segment.sequence];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            job.inFlight--;
            if (job.paused || job.cancelled) return;
            if (data.length) {
                [self writeSegment:data index:segment.index job:job];
                segment.done = YES;
                job.doneBytes += (long long)data.length;
                job.task.doneBytes = job.doneBytes;
                if (job.progressBlock) job.progressBlock(job.task);
            } else {
                segment.retries++;
                MVLogWarn(@"hls: segment %ld failed (%@), retry %ld", (long)segment.index,
                          error.localizedDescription, (long)segment.retries);
            }
            [self pumpJob:job];
        });
    });
}

- (void)writeSegment:(NSData *)data index:(NSInteger)index job:(MVHLSJob *)job {
    NSString *path = [self segmentPathForJob:job index:index];
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:path atomically:NO];
}

#pragma mark - Finish

- (void)finishJob:(MVHLSJob *)job {
    if (job.finishing) return;
    job.finishing = YES;
    MVDownloadTask *task = job.task;
    task.phase = [MVLang t:@"Joining segments"];

    NSArray<MVHLSSegment *> *segments = [job.segments copy];
    MVHLSSegment *initSegment = job.initSegment;
    BOOL isFMP4 = job.isFMP4;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *joined = [self joinedPathForJob:job];
        [fm removeItemAtPath:joined error:nil];
        [fm createFileAtPath:joined contents:nil attributes:nil];
        NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:joined];
        BOOL ok = (out != nil);
        if (initSegment) {
            NSData *initData = [NSData dataWithContentsOfFile:[self segmentPathForJob:job index:-1]];
            if (initData.length) [out writeData:initData];
        }
        for (MVHLSSegment *segment in segments) {
            if (!segment.done) { ok = NO; break; }
            NSData *chunk = [NSData dataWithContentsOfFile:[self segmentPathForJob:job index:segment.index]
                                                   options:NSDataReadingMappedIfSafe error:nil];
            if (!chunk.length) { ok = NO; break; }
            @try { [out writeData:chunk]; } @catch (NSException *e) { ok = NO; }
            if (!ok) break;
        }
        @try { [out synchronizeFile]; [out closeFile]; } @catch (NSException *e) {}
        if (!ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self failJob:job message:[MVLang t:@"Could not open the stream"]];
            });
            return;
        }

        // An fMP4 stream is already MP4. An MPEG-TS stream must be remuxed, and
        // AVFoundation does that without re-encoding the tracks.
        NSString *finalPath = joined;
        if (!isFMP4) {
            NSString *mp4 = [joined.stringByDeletingPathExtension stringByAppendingPathExtension:@"mp4"];
            BOOL remuxed = [self remuxTS:joined to:mp4];
            if (remuxed) {
                [fm removeItemAtPath:joined error:nil];
                finalPath = mp4;
            } else {
                // Keep the joined .ts so the bytes are not lost; playback may
                // still work through the share sheet or an external player.
                MVLogWarn(@"hls: remux failed, keeping .ts");
                NSString *ts = [joined.stringByDeletingPathExtension stringByAppendingPathExtension:@"ts"];
                [fm moveItemAtPath:joined toPath:ts error:nil];
                finalPath = ts;
            }
        } else {
            NSString *mp4 = [joined.stringByDeletingPathExtension stringByAppendingPathExtension:@"mp4"];
            [fm removeItemAtPath:mp4 error:nil];
            if ([fm moveItemAtPath:joined toPath:mp4 error:nil]) finalPath = mp4;
        }

        // Clean up the segment files now that the joined file exists.
        for (MVHLSSegment *segment in segments) {
            [fm removeItemAtPath:[self segmentPathForJob:job index:segment.index] error:nil];
        }
        [fm removeItemAtPath:[self segmentPathForJob:job index:-1] error:nil];

        // Move into the category folder with a collision-free name.
        NSString *directory = [MVPaths directoryForCategory:task.category];
        NSString *name = task.suggestedFilename.length ? task.suggestedFilename : finalPath.lastPathComponent;
        NSString *dest = [MVPaths uniquePathInDirectory:directory filename:name];
        NSError *moveError = nil;
        if ([fm moveItemAtPath:finalPath toPath:dest error:&moveError]) {
            finalPath = dest;
        } else {
            MVLogError(@"hls: move failed %@", moveError.localizedDescription);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSDictionary *attrs = [fm attributesOfItemAtPath:finalPath error:nil];
            long long size = [attrs[NSFileSize] longLongValue];
            task.path = finalPath;
            task.tempPath = nil;
            task.phase = nil;
            task.speed = 0;
            task.eta = 0;
            if (size > 0) task.totalBytes = size;
            task.doneBytes = task.totalBytes;
            @synchronized (self) { [_jobs removeObjectForKey:task.identifier]; }
            MVLogInfo(@"hls: finished %@ (%lld bytes) -> %@", task.title, task.totalBytes, finalPath);
            if (job.finishedBlock) job.finishedBlock(task);
        });
    });
}

/// Remuxes a joined MPEG-TS file to MP4 with AVFoundation, without re-encoding.
- (BOOL)remuxTS:(NSString *)input to:(NSString *)output {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:output error:nil];
    AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:input]];
    AVAssetExportSession *export = [AVAssetExportSession exportSessionWithAsset:asset
                                                                     presetName:AVAssetExportPresetPassthrough];
    if (!export) return NO;
    export.outputURL = [NSURL fileURLWithPath:output];
    export.outputFileType = AVFileTypeMPEG4;
    export.shouldOptimizeForNetworkUse = YES;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL ok = NO;
    [export exportAsynchronouslyWithCompletionHandler:^{
        ok = (export.status == AVAssetExportSessionStatusCompleted);
        if (!ok) MVLogError(@"hls: remux error %@", export.error.localizedDescription);
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_SEC)));
    return ok && [fm fileExistsAtPath:output];
}

#pragma mark - Failure

- (void)failJob:(MVHLSJob *)job message:(NSString *)message {
    MVDownloadTask *task = job.task;
    @synchronized (self) { [_jobs removeObjectForKey:task.identifier]; }
    MVLogError(@"hls: failed %@: %@", task.title, message);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (job.failedBlock) job.failedBlock(task, message);
    });
}

#pragma mark - Networking

/// A blocking GET on a background thread. HLS is a sequence of small requests,
/// so the simpler synchronous form keeps the playlist/segment logic readable;
/// the parallelism lives in the segment pump, not in each request.
- (NSData *)syncGet:(NSString *)url headers:(NSDictionary<NSString *, NSString *> *)headers error:(NSError **)error {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:60];
    for (NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *result = nil;
    __block NSError *resultError = nil;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
                                                              completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (err) resultError = err;
        else if (http && http.statusCode >= 400) resultError = [NSError errorWithDomain:@"MVHLS"
                                                                                 code:http.statusCode
                                                                             userInfo:@{NSLocalizedDescriptionKey:
                                                                                            [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]}];
        else result = data;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)));
    if (!result && !resultError) {
        resultError = [NSError errorWithDomain:@"MVHLS" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: [MVLang t:@"Connection timed out"]}];
    }
    if (error) *error = resultError;
    return result;
}

#pragma mark - AES-128

/// AES-128-CBC, which is what `#EXT-X-KEY:METHOD=AES-128` specifies. The IV is
/// the tag's IV or, when absent, the segment's media sequence number.
- (NSData *)decrypt:(NSData *)data key:(NSData *)key iv:(NSData *)iv sequence:(NSInteger)sequence {
    if (!key.length || !data.length) return data;
    NSMutableData *useIV = iv.length ? [iv mutableCopy] : [NSMutableData dataWithLength:16];
    if (!iv.length) {
        // Big-endian sequence number in the last 8 bytes.
        uint64_t seq = (uint64_t)sequence;
        for (NSInteger i = 0; i < 8; i++) {
            ((uint8_t *)useIV.mutableBytes)[8 + i] = (uint8_t)(seq >> (8 * (7 - i)));
        }
    }
    size_t outLength = data.length + kCCBlockSizeAES128;
    NSMutableData *out = [NSMutableData dataWithLength:outLength];
    size_t moved = 0;
    CCCryptorStatus status = CCCrypt(kCCDecrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding,
                                     key.bytes, key.length,
                                     useIV.bytes,
                                     data.bytes, data.length,
                                     out.mutableBytes, outLength, &moved);
    if (status != kCCSuccess) {
        MVLogError(@"hls: AES decrypt failed (%d)", (int)status);
        return data;   // keep the ciphertext rather than dropping the segment
    }
    out.length = moved;
    return out;
}

#pragma mark - Helpers

- (NSString *)segmentPathForJob:(MVHLSJob *)job index:(NSInteger)index {
    NSString *base = job.task.tempPath;
    if (!base.length) {
        NSString *directory = [MVPaths directoryForCategory:job.task.category];
        NSString *name = [MVPaths sanitizeFilename:job.task.suggestedFilename ?: job.task.url.lastPathComponent];
        if (!name.length) name = @"stream";
        base = [directory stringByAppendingPathComponent:
                [NSString stringWithFormat:@".%@.%@.hls", job.task.identifier, name]];
        job.task.tempPath = base;
    }
    return [NSString stringWithFormat:@"%@.seg%ld", base, (long)index];
}

- (NSString *)joinedPathForJob:(MVHLSJob *)job {
    return [NSString stringWithFormat:@"%@.joined", job.task.tempPath];
}

/// A quoted `ATTR=value` from an HLS tag, without its surrounding quotes.
- (NSString *)attribute:(NSString *)name in:(NSString *)line {
    NSString *pattern = [NSString stringWithFormat:@"%@=(\"[^\"]*\"|[^,]*)", name];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    if (!match || match.numberOfRanges < 2) return nil;
    NSString *value = [line substringWithRange:[match rangeAtIndex:1]];
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
}

- (NSString *)absoluteURL:(NSString *)url base:(NSString *)base {
    if (!url.length) return base;
    if ([url hasPrefix:@"http://"] || [url hasPrefix:@"https://"]) return url;
    return [[NSURL URLWithString:url relativeToURL:[NSURL URLWithString:base]] absoluteString];
}

/// "0x1234…" or "1234…" (16 bytes) into an NSData IV.
- (NSData *)dataFromHexIV:(NSString *)hex {
    NSString *clean = [hex lowercaseString];
    if ([clean hasPrefix:@"0x"]) clean = [clean substringFromIndex:2];
    if (clean.length % 2 != 0) clean = [@"0" stringByAppendingString:clean];
    NSMutableData *data = [NSMutableData dataWithCapacity:clean.length / 2];
    for (NSUInteger i = 0; i + 1 < clean.length; i += 2) {
        unsigned int byte = 0;
        [[NSScanner scannerWithString:[clean substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&byte];
        uint8_t b = (uint8_t)byte;
        [data appendBytes:&b length:1];
    }
    return data;
}

+ (void)removePartFilesForTask:(MVDownloadTask *)task {
    if (!task.tempPath.length) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:[NSString stringWithFormat:@"%@.joined", task.tempPath] error:nil];
    for (NSInteger i = -1; i < 4096; i++) {
        NSString *path = [NSString stringWithFormat:@"%@.seg%ld", task.tempPath, (long)i];
        if (![fm fileExistsAtPath:path]) continue;
        [fm removeItemAtPath:path error:nil];
    }
}

@end
