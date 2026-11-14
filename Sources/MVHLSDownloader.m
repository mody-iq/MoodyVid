#import "MVHLSDownloader.h"
#import "MVPaths.h"
#import "MVFileProtection.h"
#import "MVMediaProbe.h"
#import "MVHTTPSession.h"
#import "MVRequestGroup.h"
#import "MVByteRange.h"
#import "MVMediaConverter.h"
#import "MVLang.h"
#import "MVLog.h"
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonCryptor.h>
#include <limits.h>
#include <stdio.h>

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
@property (nonatomic) BOOL inFlight;
@end
@implementation MVHLSSegment
@end

/// One running HLS download.
@interface MVHLSJob : NSObject
@property (nonatomic, strong) MVDownloadTask *task;
@property (nonatomic, strong) MVRequestGroup *requests;
@property (nonatomic, strong) NSMutableArray<MVHLSSegment *> *segments;
/// The fMP4 init segment (EXT-X-MAP), if the playlist names one.
@property (nonatomic, strong, nullable) MVHLSSegment *mapSegment;
@property (nonatomic) BOOL isFMP4;
@property (nonatomic, copy) NSString *runToken;
@property (nonatomic, copy) NSString *tempPath;
@property (atomic) BOOL paused;
@property (atomic) BOOL cancelled;
@property (atomic) BOOL failureRequested;
@property (nonatomic) BOOL finishing;
@property (nonatomic) NSUInteger inFlight;
@property (nonatomic) long long doneBytes;
@property (nonatomic, copy, nullable) void (^progressBlock)(MVDownloadTask *task);
@property (nonatomic, copy, nullable) void (^finishedBlock)(MVDownloadTask *task);
@property (nonatomic, copy, nullable) void (^failedBlock)(MVDownloadTask *task, NSString *message);
@end
@implementation MVHLSJob
- (instancetype)init {
    if ((self = [super init])) { _segments = [NSMutableArray array]; _requests = [MVRequestGroup new]; }
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
    job.runToken = NSUUID.UUID.UUIDString;
    (void)[self segmentPathForJob:job index:-1];
    task.doneBytes = 0; // HLS segments are fetched again after a restart
    task.totalBytes = 0;
    @synchronized (self) { _jobs[task.identifier] = job; }
    if (progress) progress(task);
    [self fetchPlaylistForJob:job];
}

- (void)pauseTask:(MVDownloadTask *)task {
    MVHLSJob *job = nil;
    @synchronized (self) {
        job = _jobs[task.identifier];
        if (job) { job.paused = YES; [_jobs removeObjectForKey:task.identifier]; }
    }
    if (!job) return;
    [job.requests cancel];
    MVLogInfo(@"hls: paused %@ at %lld bytes", task.title, job.doneBytes);
}

- (void)cancelTask:(MVDownloadTask *)task {
    MVHLSJob *job;
    @synchronized (self) {
        job = _jobs[task.identifier];
        if (job) { job.cancelled = YES; [_jobs removeObjectForKey:task.identifier]; }
    }
    [job.requests cancel];
}

- (BOOL)isCurrentJob:(MVHLSJob *)job {
    @synchronized (self) {
        return _jobs[job.task.identifier] == job && !job.paused && !job.cancelled;
    }
}

#pragma mark - Playlist

- (void)fetchPlaylistForJob:(MVHLSJob *)job {
    NSString *url = job.task.url;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *headers = [MVMediaProbe headersForURL:url referer:job.task.referer];
        NSError *error = nil;
        NSData *data = [self syncGet:url headers:headers error:&error group:job.requests];
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
            if ([self firstVariantNeedsSeparateAudio:text]) {
                [self failJob:job message:[MVLang t:@"Separate HLS audio is not supported"]];
                return;
            }
            NSError *verror = nil;
            // A variant may live on a different host or path from the master.
            // Scope it to the page (or the original manifest for manual URLs),
            // never to the variant itself or the master's cached Cookie header.
            NSDictionary *variantHeaders = [MVMediaProbe headersForURL:variant referer:job.task.resourceContextURL];
            NSData *vdata = [self syncGet:variant headers:variantHeaders error:&verror group:job.requests];
            NSString *vtext = vdata ? [[NSString alloc] initWithData:vdata encoding:NSUTF8StringEncoding] : nil;
            if (!vtext.length) {
                [self failJob:job message:verror.localizedDescription ?: [MVLang t:@"Could not open the stream"]];
                return;
            }
            [self parseMediaPlaylist:vtext baseURL:variant into:job];
        } else {
            [self parseMediaPlaylist:text baseURL:url into:job];
        }

        if (job.paused || job.cancelled || job.failureRequested) return;
        if (!job.segments.count) {
            [self failJob:job message:[MVLang t:@"Could not open the stream"]];
            return;
        }

        // Fetch on a worker, but publish the init file only if this is still the
        // active run. A paused run must never overwrite a newer run's parts.
        NSData *initData = nil;
        if (job.mapSegment) {
            NSError *initError = nil;
            NSMutableDictionary *initHeaders = [[MVMediaProbe headersForURL:job.mapSegment.url
                                                    referer:job.task.resourceContextURL] mutableCopy];
            if (job.mapSegment.byteStart >= 0) {
                initHeaders[@"Range"] = [NSString stringWithFormat:@"bytes=%lld-%lld", job.mapSegment.byteStart,
                                         job.mapSegment.byteStart + job.mapSegment.byteLength - 1];
            }
            initData = [self syncGet:job.mapSegment.url headers:initHeaders error:&initError group:job.requests];
            if (!initData.length) {
                [self failJob:job message:[MVLang t:@"Could not open the stream"]];
                return;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isCurrentJob:job] || job.failureRequested) return;
            if (job.mapSegment && ![self writeSegment:initData index:-1 job:job]) {
                [self failJob:job message:[MVLang t:@"Could not save the file"]];
                return;
            }
            job.task.phase = [MVLang t:@"Downloading segments"];
            [self pumpJob:job];
        });
    });
}

/// This engine cannot yet combine alternate HLS audio renditions. Refuse a
/// selected variant that needs one instead of claiming a silent download worked.
- (BOOL)firstVariantNeedsSeparateAudio:(NSString *)text {
    __block NSString *group = nil;
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([trimmed hasPrefix:@"#EXT-X-STREAM-INF:"]) {
            group = [self attribute:@"AUDIO" in:trimmed];
            *stop = YES;
        }
    }];
    if (!group.length) return NO;
    __block BOOL foundGroup = NO, separate = NO;
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (![trimmed hasPrefix:@"#EXT-X-MEDIA:"]) return;
        NSString *type = [self attribute:@"TYPE" in:trimmed];
        NSString *groupID = [self attribute:@"GROUP-ID" in:trimmed];
        NSString *uri = [self attribute:@"URI" in:trimmed];
        if ([type isEqualToString:@"AUDIO"] && [groupID isEqualToString:group]) {
            foundGroup = YES;
            if (uri.length) { separate = YES; *stop = YES; }
        }
    }];
    return !foundGroup || separate;
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
    __block long long pendingLength = -1, pendingStart = -1, lastRangeEnd = -1;
    __block NSString *lastRangeURL = nil;
    __block BOOL hasPendingRange = NO, hasEndList = NO, sawMap = NO;
    __block BOOL invalidRange = NO, invalidMap = NO, invalidKey = NO, unsupported = NO;
    __block NSString *mapURL = nil;
    __block long long mapStart = -1, mapLength = -1;
    __block long long mediaSequence = 0;

    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!trimmed.length) return;
        if ([trimmed isEqualToString:@"#EXT-X-ENDLIST"]) { hasEndList = YES; return; }
        if ([trimmed isEqualToString:@"#EXT-X-DISCONTINUITY"] ||
            [trimmed isEqualToString:@"#EXT-X-GAP"] ||
            [trimmed isEqualToString:@"#EXT-X-I-FRAMES-ONLY"] ||
            [trimmed hasPrefix:@"#EXT-X-STREAM-INF:"]) {
            unsupported = YES;
            return;
        }
        if ([trimmed hasPrefix:@"#EXT-X-MEDIA-SEQUENCE:"]) {
            NSString *value = [trimmed substringFromIndex:[@"#EXT-X-MEDIA-SEQUENCE:" length]];
            NSScanner *scanner = [NSScanner scannerWithString:value];
            if (job.segments.count || ![scanner scanLongLong:&mediaSequence] || !scanner.isAtEnd ||
                mediaSequence < 0 || mediaSequence > NSIntegerMax) invalidRange = YES;
            return;
        }
        if ([trimmed hasPrefix:@"#EXT-X-MAP:"]) {
            if (sawMap || job.segments.count) invalidMap = YES;
            sawMap = YES;
            NSString *uri = [self attribute:@"URI" in:trimmed];
            mapURL = uri.length ? [self absoluteURL:uri base:base] : nil;
            if (!mapURL.length) invalidMap = YES;
            NSString *range = [self attribute:@"BYTERANGE" in:trimmed];
            if (range.length) {
                NSArray<NSString *> *parts = [range componentsSeparatedByString:@"@"];
                NSScanner *lengthScanner = [NSScanner scannerWithString:parts.firstObject];
                NSScanner *startScanner = parts.count == 2 ? [NSScanner scannerWithString:parts.lastObject] : nil;
                if (parts.count != 2 || ![lengthScanner scanLongLong:&mapLength] || !lengthScanner.isAtEnd ||
                    ![startScanner scanLongLong:&mapStart] || !startScanner.isAtEnd || mapLength <= 0 ||
                    mapStart < 0 || mapStart > LLONG_MAX - mapLength) invalidMap = YES;
            }
            if (currentKey && ![currentKey.method isEqualToString:@"NONE"]) invalidMap = YES;
            return;
        }
        if ([trimmed hasPrefix:@"#EXT-X-KEY:"]) {
            NSString *method = [self attribute:@"METHOD" in:trimmed];
            NSString *format = [self attribute:@"KEYFORMAT" in:trimmed];
            MVHLSKey *key = [MVHLSKey new];
            key.method = method ?: @"";
            if (!method.length || (format.length && ![format isEqualToString:@"identity"])) invalidKey = YES;
            if (![method isEqualToString:@"NONE"]) {
                NSString *uri = [self attribute:@"URI" in:trimmed];
                if (uri.length) key.uri = [self absoluteURL:uri base:base];
                NSString *iv = [self attribute:@"IV" in:trimmed];
                if (iv.length) {
                    key.iv = [self dataFromHexIV:iv];
                    if (!key.iv) invalidKey = YES;
                }
                if (![method isEqualToString:@"AES-128"] || !key.uri.length) invalidKey = YES;
            }
            currentKey = key;
            return;
        }
        if ([trimmed hasPrefix:@"#EXT-X-BYTERANGE:"]) {
            // An omitted offset is legal only immediately after a range of the
            // same resource. Defer that check until the URI line is known.
            if (hasPendingRange) invalidRange = YES;
            NSString *value = [trimmed substringFromIndex:[@"#EXT-X-BYTERANGE:" length]];
            NSArray<NSString *> *parts = [value componentsSeparatedByString:@"@"];
            pendingLength = -1;
            pendingStart = -1;
            NSScanner *lengthScanner = [NSScanner scannerWithString:parts.firstObject];
            NSScanner *startScanner = parts.count == 2 ? [NSScanner scannerWithString:parts.lastObject] : nil;
            if (parts.count > 2 || ![lengthScanner scanLongLong:&pendingLength] || !lengthScanner.isAtEnd ||
                (startScanner && (![startScanner scanLongLong:&pendingStart] || !startScanner.isAtEnd)) ||
                pendingLength <= 0 || (parts.count == 2 && pendingStart < 0)) invalidRange = YES;
            hasPendingRange = YES;
            return;
        }
        if ([trimmed hasPrefix:@"#"]) return;

        NSString *absolute = [self absoluteURL:trimmed base:base];
        if (!absolute.length || job.segments.count >= 100000 ||
            mediaSequence > NSIntegerMax - (long long)job.segments.count) {
            invalidRange = YES;
            return;
        }
        long long start = -1, length = -1;
        if (hasPendingRange) {
            start = pendingStart;
            length = pendingLength;
            if (start < 0) {
                if (lastRangeEnd < 0 || ![absolute isEqualToString:lastRangeURL]) invalidRange = YES;
                else start = lastRangeEnd + 1;
            }
            if (length <= 0 || start < 0 || start > LLONG_MAX - length) invalidRange = YES;
            else {
                lastRangeEnd = start + length - 1;
                lastRangeURL = absolute;
            }
        } else {
            lastRangeEnd = -1;
            lastRangeURL = nil;
        }
        MVHLSSegment *segment = [MVHLSSegment new];
        segment.index = (NSInteger)job.segments.count;
        segment.sequence = (NSInteger)(mediaSequence + segment.index);
        segment.byteStart = start;
        segment.byteLength = length;
        segment.key = currentKey;
        segment.url = absolute;
        [job.segments addObject:segment];
        hasPendingRange = NO;
    }];

    if (!hasEndList) {
        [self failJob:job message:[MVLang t:@"Live streams can't be downloaded"]];
        return;
    }
    if (invalidRange || hasPendingRange || ![text containsString:@"#EXTM3U"]) {
        [self failJob:job message:[MVLang t:@"Could not open the stream"]];
        return;
    }
    if (invalidMap) {
        [self failJob:job message:[MVLang t:@"Unsupported HLS initialization segment"]];
        return;
    }
    if (invalidKey) {
        [self failJob:job message:[MVLang t:@"This stream is protected and can't be downloaded"]];
        return;
    }
    if (unsupported) {
        [self failJob:job message:[MVLang t:@"Unsupported HLS playlist"]];
        return;
    }
    if (mapURL.length) {
        MVHLSSegment *init = [MVHLSSegment new];
        init.index = -1;
        init.url = mapURL;
        init.byteStart = mapStart;
        init.byteLength = mapLength;
        job.mapSegment = init;
        job.isFMP4 = YES;
    }

    // Fetch each distinct key once, up front. Reuse key bytes, not the key tag,
    // since different tags can carry different IVs for the same URI.
    NSMutableDictionary<NSString *, NSData *> *byURI = [NSMutableDictionary dictionary];
    for (MVHLSSegment *segment in job.segments) {
        if (job.paused || job.cancelled) return;
        MVHLSKey *key = segment.key;
        if (!key || [key.method isEqualToString:@"NONE"]) continue;
        NSData *existing = byURI[key.uri];
        if (existing) { key.data = existing; continue; }
        NSError *keyError = nil;
        NSData *keyData = [self syncGet:key.uri
                                headers:[MVMediaProbe headersForURL:key.uri referer:job.task.resourceContextURL]
                                  error:&keyError group:job.requests];
        if (keyData.length != 16) {
            [self failJob:job message:[MVLang t:@"Could not open the stream"]];
            return;
        }
        key.data = keyData;
        byURI[key.uri] = keyData;
    }
}

#pragma mark - Segments

- (void)pumpJob:(MVHLSJob *)job {
    if (![self isCurrentJob:job] || job.failureRequested || job.finishing) return;
    while (job.inFlight < (NSUInteger)kMaxParallelSegments) {
        MVHLSSegment *next = nil;
        for (MVHLSSegment *segment in job.segments) {
            if (!segment.done && !segment.inFlight && segment.retries < kMaxSegmentRetries) { next = segment; break; }
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
    segment.inFlight = YES;
    job.inFlight++;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (job.paused || job.cancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{ segment.inFlight = NO; job.inFlight--; });
            return;
        }
        NSDictionary *headers = [MVMediaProbe headersForURL:segment.url referer:job.task.resourceContextURL];
        if (segment.byteStart >= 0) {
            NSMutableDictionary *mutable = [headers mutableCopy];
            mutable[@"Range"] = [NSString stringWithFormat:@"bytes=%lld-%lld",
                                 segment.byteStart, segment.byteStart + segment.byteLength - 1];
            headers = mutable;
        }
        NSError *error = nil;
        NSData *data = [self syncGet:segment.url headers:headers error:&error group:job.requests];
        if (data && segment.key.data && [segment.key.method isEqualToString:@"AES-128"]) {
            data = [self decrypt:data key:segment.key.data iv:segment.key.iv sequence:segment.sequence];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            job.inFlight--;
            segment.inFlight = NO;
            if (![self isCurrentJob:job] || job.failureRequested || job.finishing) return;
            if (data.length) {
                if (![self writeSegment:data index:segment.index job:job]) {
                    [self failJob:job message:[MVLang t:@"Could not save the file"]];
                    return;
                }
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

- (BOOL)writeSegment:(NSData *)data index:(NSInteger)index job:(MVHLSJob *)job {
    NSString *path = [self segmentPathForJob:job index:index];
    if (![MVFileProtection isSafePartialItemAtPath:path] ||
        [MVFileProtection path:path conflictsWithPaths:[MVFileProtection pathsExcludingTask:job.task record:nil]]) return NO;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                   withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    return [data writeToFile:path atomically:YES];
}

#pragma mark - Finish

- (NSString *)runPathForJob:(MVHLSJob *)job kind:(NSString *)kind extension:(NSString *)extension {
    return [NSString stringWithFormat:@"%@.%@-%@.%@", job.tempPath, kind, job.runToken, extension];
}

- (void)removeRunOutputsForJob:(MVHLSJob *)job {
    NSArray *protected = [MVFileProtection pathsExcludingTask:job.task record:nil];
    [MVFileProtection removePartialItemAtPath:[self runPathForJob:job kind:@"joining" extension:(job.isFMP4 ? @"mp4" : @"ts")]
                                  protecting:protected];
    [MVFileProtection removePartialItemAtPath:[self runPathForJob:job kind:@"remux" extension:@"mp4"]
                                  protecting:protected];
}

- (void)finishJob:(MVHLSJob *)job {
    if (job.finishing || ![self isCurrentJob:job]) return;
    job.finishing = YES;
    job.task.phase = [MVLang t:@"Joining segments"];
    if (job.progressBlock) job.progressBlock(job.task);
    NSArray<MVHLSSegment *> *segments = [job.segments copy];
    MVHLSSegment *mapSegment = job.mapSegment;
    NSString *joined = [self runPathForJob:job kind:@"joining" extension:(job.isFMP4 ? @"mp4" : @"ts")];
    NSString *mp4 = [self runPathForJob:job kind:@"remux" extension:@"mp4"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:joined error:nil];
        BOOL ok = [fm createFileAtPath:joined contents:nil attributes:nil];
        NSFileHandle *out = ok ? [NSFileHandle fileHandleForWritingAtPath:joined] : nil;
        ok = out != nil && segments.count > 0;
        NSMutableArray<MVHLSSegment *> *ordered = [NSMutableArray array];
        if (mapSegment) [ordered addObject:mapSegment];
        [ordered addObjectsFromArray:segments];
        for (MVHLSSegment *segment in ordered) {
            if (!ok) break;
            if (segment != mapSegment && !segment.done) { ok = NO; break; }
            NSString *path = [self segmentPathForJob:job index:segment.index];
            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
            if (!attrs || [attrs[NSFileSize] longLongValue] <= 0) { ok = NO; break; }
            NSFileHandle *in = [NSFileHandle fileHandleForReadingAtPath:path];
            if (!in) { ok = NO; break; }
            @try {
                while (YES) {
                    @autoreleasepool {
                        NSData *chunk = [in readDataOfLength:1024 * 1024];
                        if (!chunk.length) break;
                        [out writeData:chunk];
                    }
                }
                [in closeFile];
            } @catch (NSException *exception) { ok = NO; }
            if (!ok) break;
        }
        @try { [out synchronizeFile]; [out closeFile]; } @catch (NSException *exception) { ok = NO; }

        NSString *result = joined;
        NSString *extension = job.isFMP4 ? @"mp4" : @"ts";
        if (ok && job.isFMP4) {
            BOOL video = [MVMediaConverter hasVideoTrack:joined];
            BOOL audio = [MVMediaConverter hasAudioTrack:joined];
            ok = video || audio;
            if (!video && audio) extension = @"m4a";
        }
        if (ok && !job.isFMP4 && !job.paused && !job.cancelled) {
            if ([self remuxTS:joined to:mp4]) { result = mp4; extension = @"mp4"; }
            else MVLogWarn(@"hls: remux failed, keeping .ts");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isCurrentJob:job]) { [self removeRunOutputsForJob:job]; return; }
            if (!ok) { [self failJob:job message:[MVLang t:@"Could not open the stream"]]; return; }
            MVDownloadTask *task = job.task;
            NSString *directory = [MVPaths directoryForCategory:task.category];
            NSString *base = task.suggestedFilename.length ? task.suggestedFilename.stringByDeletingPathExtension : @"stream";
            NSString *dest = [MVPaths uniquePathInDirectory:directory filename:[base stringByAppendingPathExtension:extension]];
            if (![fm moveItemAtPath:result toPath:dest error:nil]) {
                [self failJob:job message:[MVLang t:@"Could not save the file"]];
                return;
            }
            [self removeRunOutputsForJob:job];
            [MVHLSDownloader removePartFilesForTask:task];
            long long size = [[fm attributesOfItemAtPath:dest error:nil][NSFileSize] longLongValue];
            task.path = dest;
            task.tempPath = nil;
            task.phase = nil;
            task.speed = 0;
            task.eta = 0;
            task.totalBytes = size;
            task.doneBytes = size;
            @synchronized (self) { if (_jobs[task.identifier] == job) [_jobs removeObjectForKey:task.identifier]; }
            MVLogInfo(@"hls: finished %@ (%lld bytes) -> %@", task.title, size, dest);
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
    long timedOut = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600LL * NSEC_PER_SEC)));
    if (timedOut) {
        [export cancelExport];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            [fm removeItemAtPath:output error:nil];
        });
        return NO;
    }
    return ok && [fm fileExistsAtPath:output];
}

#pragma mark - Failure

- (void)failJob:(MVHLSJob *)job message:(NSString *)message {
    job.failureRequested = YES;
    void (^finishFailure)(void) = ^{
        if (![self isCurrentJob:job]) return;
        @synchronized (self) { if (_jobs[job.task.identifier] == job) [_jobs removeObjectForKey:job.task.identifier]; }
        [job.requests cancel];
        [self removeRunOutputsForJob:job];
        MVLogError(@"hls: failed %@: %@", job.task.title, message);
        if (job.failedBlock) job.failedBlock(job.task, message);
    };
    if (NSThread.isMainThread) finishFailure();
    else dispatch_async(dispatch_get_main_queue(), finishFailure);
}

#pragma mark - Networking

/// A blocking GET on a background thread. HLS is a sequence of small requests,
/// so the simpler synchronous form keeps the playlist/segment logic readable;
/// the parallelism lives in the segment pump, not in each request.
- (NSData *)syncGet:(NSString *)url headers:(NSDictionary<NSString *, NSString *> *)headers error:(NSError **)error {
    return [self syncGet:url headers:headers error:error group:nil];
}

- (NSData *)syncGet:(NSString *)url headers:(NSDictionary<NSString *, NSString *> *)headers
              error:(NSError **)error group:(MVRequestGroup *)group {
    NSURL *target = [NSURL URLWithString:url];
    if (!target || ![@[@"http", @"https"] containsObject:target.scheme.lowercaseString]) {
        if (error) *error = [NSError errorWithDomain:@"MVHLS" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: [MVLang t:@"Could not open the stream"]}];
        return nil;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:target
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:60];
    request.HTTPShouldHandleCookies = NO;
    request.allowsCellularAccess = ![NSUserDefaults.standardUserDefaults boolForKey:@"MVWifiOnly"];
    for (NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    NSString *rangeHeader = [request valueForHTTPHeaderField:@"Range"];
    long long requestedStart = -1, requestedEnd = -1;
    if (rangeHeader.length) {
        NSScanner *scanner = [NSScanner scannerWithString:rangeHeader];
        if (![scanner scanString:@"bytes=" intoString:nil] || ![scanner scanLongLong:&requestedStart] ||
            ![scanner scanString:@"-" intoString:nil] || ![scanner scanLongLong:&requestedEnd] || !scanner.isAtEnd ||
            requestedStart < 0 || requestedEnd < requestedStart || requestedEnd == LLONG_MAX) {
            if (error) *error = [NSError errorWithDomain:@"MVHLS" code:-1
                userInfo:@{NSLocalizedDescriptionKey: [MVLang t:@"Server did not honor the requested byte range"]}];
            return nil;
        }
    }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *result = nil;
    __block NSError *resultError = nil;
    __block __weak NSURLSessionDataTask *weakTask = nil;
    NSURLSessionDataTask *task = [MVHTTPSession.sharedSession dataTaskWithRequest:request
                                                              completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (err) resultError = err;
        else if (!http || http.statusCode < 200 || http.statusCode >= 300) {
            resultError = [NSError errorWithDomain:@"MVHLS" code:http.statusCode
                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]}];
        } else if (rangeHeader.length) {
            NSString *contentRange = [http valueForHTTPHeaderField:@"Content-Range"];
            NSString *encoding = [http valueForHTTPHeaderField:@"Content-Encoding"];
            MVContentRange parsed;
            if (http.statusCode != 206 ||
                (encoding.length && [encoding caseInsensitiveCompare:@"identity"] != NSOrderedSame) ||
                !MVParseContentRange(contentRange.UTF8String, &parsed) ||
                !MVContentRangeMatches(&parsed, requestedStart, requestedEnd, -1) ||
                (long long)data.length != requestedEnd - requestedStart + 1) {
                resultError = [NSError errorWithDomain:@"MVHLS" code:-1
                    userInfo:@{NSLocalizedDescriptionKey: [MVLang t:@"Server did not honor the requested byte range"]}];
            } else result = data;
        } else if (http.statusCode == 200) result = data;
        else resultError = [NSError errorWithDomain:@"MVHLS" code:http.statusCode
            userInfo:@{NSLocalizedDescriptionKey: [MVLang t:@"Download incomplete"]}];
        [group finishTask:weakTask];
        dispatch_semaphore_signal(sem);
    }];
    weakTask = task;
    if (group ? ![group startTask:task] : NO) {
        if (error) *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
        return nil;
    }
    if (!group) [task resume];
    long timedOut = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)));
    if (timedOut) {
        [task cancel];
        if (error) *error = [NSError errorWithDomain:@"MVHLS" code:-1
                                           userInfo:@{NSLocalizedDescriptionKey: [MVLang t:@"Connection timed out"]}];
        return nil; // do not race the completion handler after a timeout
    }
    if (error) *error = resultError;
    return result;
}

#pragma mark - AES-128

/// AES-128-CBC, which is what `#EXT-X-KEY:METHOD=AES-128` specifies. The IV is
/// the tag's IV or, when absent, the segment's media sequence number.
- (NSData *)decrypt:(NSData *)data key:(NSData *)key iv:(NSData *)iv sequence:(NSInteger)sequence {
    if (key.length != 16 || !data.length || (iv.length && iv.length != 16)) return nil;
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
        return nil;   // ciphertext must never be reported as playable media
    }
    out.length = moved;
    return out;
}

#pragma mark - Helpers

- (NSString *)segmentPathForJob:(MVHLSJob *)job index:(NSInteger)index {
    NSString *base = job.tempPath;
    if (!base.length) {
        base = job.task.tempPath;
        if (!base.length) {
            NSString *directory = [MVPaths directoryForCategory:job.task.category];
            NSString *name = [MVPaths sanitizeFilename:job.task.suggestedFilename ?: job.task.url.lastPathComponent];
            if (!name.length) name = @"stream";
            base = [directory stringByAppendingPathComponent:
                    [NSString stringWithFormat:@".%@.%@.hls", job.task.identifier, name]];
            job.task.tempPath = base;
        }
        job.tempPath = base;
    }
    return [NSString stringWithFormat:@"%@.seg%ld", base, (long)index];
}

/// An exact HLS attribute name/value (not a suffix such as X-URI).
- (NSString *)attribute:(NSString *)name in:(NSString *)line {
    NSString *pattern = [NSString stringWithFormat:@"(?:^|[:,])[ \\t]*%@[ \\t]*=(\"[^\"]*\"|[^,]*)",
                         [NSRegularExpression escapedPatternForString:name]];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    if (!match || match.numberOfRanges < 2) return nil;
    NSString *value = [[line substringWithRange:[match rangeAtIndex:1]]
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([value hasPrefix:@"\""]) {
        if (value.length < 2 || ![value hasSuffix:@"\""]) return nil;
        value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
    }
    return value;
}

- (NSString *)absoluteURL:(NSString *)url base:(NSString *)base {
    if (!url.length) return base;
    if ([url hasPrefix:@"http://"] || [url hasPrefix:@"https://"]) return url;
    return [[NSURL URLWithString:url relativeToURL:[NSURL URLWithString:base]] absoluteString];
}

/// A hexadecimal IV is a 128-bit big-endian number, left-padded with zeroes.
- (NSData *)dataFromHexIV:(NSString *)hex {
    NSString *clean = hex.lowercaseString;
    if ([clean hasPrefix:@"0x"]) clean = [clean substringFromIndex:2];
    if (!clean.length || clean.length > 32) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:16];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < clean.length; i++) {
        unichar c = [clean characterAtIndex:clean.length - i - 1];
        int digit = c >= '0' && c <= '9' ? c - '0' : (c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1);
        if (digit < 0) return nil;
        bytes[15 - i / 2] |= (uint8_t)(digit << ((i % 2) * 4));
    }
    return data;
}

+ (void)removePartFilesForTask:(MVDownloadTask *)task {
    if (![MVFileProtection isSafePartialBase:task.tempPath]) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *protected = [MVFileProtection pathsExcludingTask:task record:nil];
    NSString *directory = task.tempPath.stringByDeletingLastPathComponent;
    NSString *prefix = [task.tempPath.lastPathComponent stringByAppendingString:@"."];
    for (NSString *name in [fm contentsOfDirectoryAtPath:directory error:nil]) {
        if (![name hasPrefix:prefix]) continue;
        NSString *suffix = [name substringFromIndex:prefix.length];
        if ([suffix hasPrefix:@"seg"] || [suffix hasPrefix:@"joining-"] || [suffix hasPrefix:@"remux-"] ||
            [suffix isEqualToString:@"joined"] || [suffix isEqualToString:@"mp4"] || [suffix isEqualToString:@"ts"]) {
            [MVFileProtection removePartialItemAtPath:[directory stringByAppendingPathComponent:name] protecting:protected];
        }
    }
}

@end
