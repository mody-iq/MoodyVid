#import "MVMPDDownloader.h"
#import "MVPaths.h"
#import "MVFileProtection.h"
#import "MVMediaProbe.h"
#import "MVHTTPSession.h"
#import "MVRequestGroup.h"
#import "MVByteRange.h"
#import "MVMediaConverter.h"
#import "MVLang.h"
#import "MVLog.h"
#include <limits.h>
#include <math.h>

/// How many media segments are fetched at once, matching the HLS engine.
static const NSInteger kMaxParallelSegments = 4;
/// Retries per segment before the whole task fails.
static const NSInteger kMaxSegmentRetries = 3;
/// A runaway guard: a manifest that expands past this is malformed, not real.
static const NSInteger kMaxSegments = 100000;

#pragma mark - Model

/// One media segment: where to get it, which bytes, and whether it landed.
@interface MVMPDSegment : NSObject
@property (nonatomic) NSInteger index;
@property (nonatomic, copy) NSString *url;
@property (nonatomic) long long byteStart;    ///< -1 when the whole resource
@property (nonatomic) long long byteLength;   ///< -1 when the whole resource
@property (nonatomic) NSInteger retries;
@property (nonatomic) BOOL done;
@property (nonatomic) BOOL inFlight;
@end
@implementation MVMPDSegment
@end

/// One `<Representation>`, flattened to the addressing forms a downloader uses.
@interface MVMPDRepresentation : NSObject
@property (nonatomic, copy) NSString *repID;
@property (nonatomic) double bandwidth;
@property (nonatomic, copy, nullable) NSString *mimeType;
@property (nonatomic, copy, nullable) NSString *contentType;
@property (nonatomic, copy, nullable) NSString *codecs;
/// The base URL this representation's relative URLs resolve against.
@property (nonatomic, copy, nullable) NSString *base;
/// Addressing explicitly declared at this representation, if any.
@property (nonatomic, copy, nullable) NSString *addressingKind;
/// SegmentTemplate addressing.
@property (nonatomic, copy, nullable) NSString *mediaTemplate;
@property (nonatomic, copy, nullable) NSString *mapTemplate;
@property (nonatomic) NSInteger startNumber;
@property (nonatomic) BOOL startNumberSpecified;
@property (nonatomic) double timescale;
@property (nonatomic) double duration;
/// SegmentTimeline entries, each @{@"t": NSNumber, @"d": NSNumber, @"r": NSNumber}.
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *timeline;
/// SegmentList addressing.
@property (nonatomic, copy, nullable) NSString *listInit;
@property (nonatomic, copy, nullable) NSString *listInitRange;
@property (nonatomic) BOOL listHasInit;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *listURLs;   ///< @{url, range}
/// SegmentBase addressing: the init byte range inside the single resource.
@property (nonatomic) long long mapStart;
@property (nonatomic) long long mapLength;
/// YES when a `<BaseURL>` was declared for this representation (or its
/// AdaptationSet), so a single-resource download has a real media URL.
@property (nonatomic) BOOL hasBase;
@property (nonatomic) BOOL isVideo;
@property (nonatomic) BOOL isAudio;
@end
@implementation MVMPDRepresentation
- (instancetype)init {
    if ((self = [super init])) {
        _timeline = [NSMutableArray array];
        _listURLs = [NSMutableArray array];
        _startNumber = 1;
        _mapStart = -1;
        _mapLength = -1;
    }
    return self;
}
@end

/// One running DASH download.
@interface MVMPDJob : NSObject
@property (nonatomic, strong) MVDownloadTask *task;
@property (nonatomic, strong) MVRequestGroup *requests;
@property (nonatomic, strong) NSMutableArray<MVMPDSegment *> *segments;
@property (nonatomic, strong, nullable) MVMPDSegment *mapSegment;
@property (nonatomic, strong, nullable) MVMPDSegment *audioMapSegment;
@property (nonatomic) NSUInteger primarySegmentCount;
@property (nonatomic) BOOL hasSeparateAudio;
@property (nonatomic) BOOL audioOnly;
@property (nonatomic, copy) NSString *runToken;
@property (nonatomic, copy) NSString *tempPath;
@property (atomic) BOOL paused;
@property (atomic) BOOL cancelled;
@property (nonatomic) BOOL finishing;
@property (nonatomic) NSUInteger inFlight;
@property (nonatomic) long long doneBytes;
@property (nonatomic, copy, nullable) void (^progressBlock)(MVDownloadTask *task);
@property (nonatomic, copy, nullable) void (^finishedBlock)(MVDownloadTask *task);
@property (nonatomic, copy, nullable) void (^failedBlock)(MVDownloadTask *task, NSString *message);
@end
@implementation MVMPDJob
- (instancetype)init {
    if ((self = [super init])) { _segments = [NSMutableArray array]; _requests = [MVRequestGroup new]; }
    return self;
}
@end

#pragma mark - Manifest parser

/// A small NSXMLParser delegate that flattens an MPD into representations.
/// Only the elements a downloader needs are read; everything else is ignored,
/// which keeps it tolerant of the extra metadata real manifests carry.
@interface MVMPDParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, copy) NSString *manifestURL;
@property (nonatomic, strong) NSMutableArray<MVMPDRepresentation *> *representations;
@property (nonatomic) BOOL isLive;
@property (nonatomic) BOOL isProtected;
/// The whole-presentation duration in seconds, 0 when absent.
@property (nonatomic) double presentationDuration;
/// The current Period duration in seconds, 0 when absent.
@property (nonatomic) double periodDuration;
@property (nonatomic) NSUInteger periodCount;
- (instancetype)initWithURL:(NSString *)url;
- (BOOL)parse:(NSData *)data;
@end

@implementation MVMPDParser {
    NSMutableArray<NSString *> *_baseStack;
    NSMutableArray<NSNumber *> *_baseHasURL;
    NSMutableArray<NSNumber *> *_baseDeclaredHere;
    NSMutableString *_textBuffer;
    MVMPDRepresentation *_currentRep;
    BOOL _inPeriod;
    BOOL _inAdaptationSet;
    // Segment addressing may be inherited from a Period or AdaptationSet.
    NSMutableDictionary *_periodTemplate;
    NSMutableDictionary *_periodList;
    NSMutableDictionary *_periodBase;
    NSString *_periodKind;
    NSString *_setKind;
    NSMutableDictionary *_setTemplate;
    NSMutableDictionary *_setList;
    NSMutableDictionary *_setBase;
    NSString *_setMimeType;
    NSString *_setContentType;
    NSString *_setCodecs;
    // The SegmentTemplate/SegmentList/SegmentBase currently open, so its
    // children (SegmentTimeline, SegmentURL) land in the right place.
    NSMutableDictionary *_openTemplate;
    NSMutableDictionary *_openList;
    NSMutableDictionary *_openBase;
    BOOL _inTimeline;
}

- (instancetype)initWithURL:(NSString *)url {
    if ((self = [super init])) {
        _manifestURL = [url copy];
        _representations = [NSMutableArray array];
        _baseStack = [NSMutableArray arrayWithObject:url];
        _baseHasURL = [NSMutableArray arrayWithObject:@NO];
        _baseDeclaredHere = [NSMutableArray arrayWithObject:@NO];
        _textBuffer = [NSMutableString string];
    }
    return self;
}

- (BOOL)parse:(NSData *)data {
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = self;
    parser.shouldProcessNamespaces = NO;
    parser.shouldResolveExternalEntities = NO;
    return [parser parse];
}

- (void)pushBaseScope {
    [_baseStack addObject:_baseStack.lastObject];
    [_baseHasURL addObject:_baseHasURL.lastObject];
    [_baseDeclaredHere addObject:@NO];
}

- (void)popBaseScope {
    if (_baseStack.count <= 1) return;
    [_baseStack removeLastObject];
    [_baseHasURL removeLastObject];
    [_baseDeclaredHere removeLastObject];
}

/// The element's local name without a namespace prefix, lower-cased.
- (NSString *)nameOf:(NSString *)elementName {
    return [[elementName componentsSeparatedByString:@":"].lastObject lowercaseString];
}

- (void)parser:(NSXMLParser *)parser
didStartElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qName
    attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    NSString *name = [self nameOf:elementName];

    if ([name isEqualToString:@"mpd"]) {
        self.presentationDuration = [self secondsFromISO8601Duration:attributes[@"mediaPresentationDuration"]];
        if ([attributes[@"type"] isEqualToString:@"dynamic"]) self.isLive = YES;
        return;
    }

    if ([name isEqualToString:@"period"]) {
        [self pushBaseScope];
        _inPeriod = YES;
        self.periodCount++;
        self.periodDuration = [self secondsFromISO8601Duration:attributes[@"duration"]];
        _periodTemplate = nil; _periodList = nil; _periodBase = nil; _periodKind = nil;
        _setTemplate = nil; _setList = nil; _setBase = nil; _setKind = nil;
        return;
    }

    if ([name isEqualToString:@"adaptationset"]) {
        [self pushBaseScope];
        _inAdaptationSet = YES;
        _setTemplate = nil; _setList = nil; _setBase = nil; _setKind = nil;
        _setMimeType = attributes[@"mimeType"];
        _setContentType = attributes[@"contentType"];
        _setCodecs = attributes[@"codecs"];
        return;
    }

    if ([name isEqualToString:@"representation"]) {
        [self pushBaseScope];
        MVMPDRepresentation *rep = [MVMPDRepresentation new];
        rep.repID = attributes[@"id"];
        rep.bandwidth = [attributes[@"bandwidth"] doubleValue];
        rep.mimeType = attributes[@"mimeType"] ?: _setMimeType;
        rep.contentType = attributes[@"contentType"] ?: _setContentType;
        rep.codecs = attributes[@"codecs"] ?: _setCodecs;
        rep.startNumber = 1; // DASH default; SegmentTemplate may override it.
        _currentRep = rep;
        return;
    }

    if ([name isEqualToString:@"baseurl"]) {
        [_textBuffer setString:@""];
        return;
    }

    if ([name isEqualToString:@"contentprotection"]) {
        // Any ContentProtection means the media is encrypted (CENC/Widevine/
        // PlayReady/FairPlay); there is no key here, so it cannot be saved as a
        // plain file.
        self.isProtected = YES;
        return;
    }

    if ([name isEqualToString:@"segmenttemplate"]) {
        NSMutableDictionary *t = [NSMutableDictionary dictionary];
        t[@"media"] = attributes[@"media"] ?: @"";
        t[@"initialization"] = attributes[@"initialization"] ?: @"";
        t[@"startNumber"] = attributes[@"startNumber"];
        t[@"timescale"] = attributes[@"timescale"];
        t[@"duration"] = attributes[@"duration"];
        t[@"timeline"] = [NSMutableArray array];
        _openTemplate = t;
        if (_currentRep) _currentRep.addressingKind = @"template";
        else if (_inAdaptationSet) { _setTemplate = t; _setKind = @"template"; }
        else if (_inPeriod) { _periodTemplate = t; _periodKind = @"template"; }
        return;
    }

    if ([name isEqualToString:@"segmenttimeline"]) {
        _inTimeline = YES;
        return;
    }

    if ([name isEqualToString:@"s"] && _inTimeline) {
        NSDictionary *entry = @{@"t": @(attributes[@"t"] ? attributes[@"t"].longLongValue : -1),
                                @"d": @(attributes[@"d"] ? attributes[@"d"].longLongValue : 0),
                                @"r": @(attributes[@"r"] ? attributes[@"r"].integerValue : 0)};
        NSMutableArray *timeline = _openTemplate[@"timeline"];
        if (timeline) [timeline addObject:entry];
        return;
    }

    if ([name isEqualToString:@"segmentlist"]) {
        NSMutableDictionary *l = [NSMutableDictionary dictionary];
        l[@"initialization"] = attributes[@"initialization"] ?: @"";
        l[@"hasInit"] = @((attributes[@"initialization"].length > 0));
        l[@"urls"] = [NSMutableArray array];
        _openList = l;
        if (_currentRep) _currentRep.addressingKind = @"list";
        else if (_inAdaptationSet) { _setList = l; _setKind = @"list"; }
        else if (_inPeriod) { _periodList = l; _periodKind = @"list"; }
        return;
    }

    if ([name isEqualToString:@"initialization"]) {
        NSMutableDictionary *list = _openList;
        NSMutableDictionary *base = _openBase;
        if (list) {
            list[@"hasInit"] = @YES;
            list[@"initialization"] = attributes[@"sourceURL"] ?: @"";
            list[@"initRange"] = attributes[@"range"] ?: @"";
        } else if (base && attributes[@"range"].length) {
            base[@"initialization"] = attributes[@"range"];
        }
        return;
    }

    if ([name isEqualToString:@"segmenturl"]) {
        NSString *media = attributes[@"media"];
        if (media.length || [attributes[@"mediaRange"] length]) {
            NSDictionary *entry = @{@"url": media ?: @"", @"range": attributes[@"mediaRange"] ?: @""};
            NSMutableArray *urls = _openList[@"urls"];
            if (urls) [urls addObject:entry];
        }
        return;
    }

    if ([name isEqualToString:@"segmentbase"]) {
        NSMutableDictionary *b = [NSMutableDictionary dictionary];
        b[@"initialization"] = attributes[@"initialization"] ?: @"";
        _openBase = b;
        if (_currentRep) _currentRep.addressingKind = @"base";
        else if (_inAdaptationSet) { _setBase = b; _setKind = @"base"; }
        else if (_inPeriod) { _periodBase = b; _periodKind = @"base"; }
        return;
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    if (_textBuffer) [_textBuffer appendString:string];
}

- (void)parser:(NSXMLParser *)parser
 didEndElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qName {
    NSString *name = [self nameOf:elementName];

    if ([name isEqualToString:@"baseurl"]) {
        NSString *text = [_textBuffer stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (text.length && _baseStack.count && ![_baseDeclaredHere.lastObject boolValue]) {
            NSString *resolved = [self absoluteURL:text base:_baseStack.lastObject];
            if (resolved.length) {
                NSUInteger scope = _baseStack.count - 1;
                _baseStack[scope] = resolved;
                _baseHasURL[scope] = @YES;
                _baseDeclaredHere[scope] = @YES; // alternatives are not nested paths
            }
        }
        [_textBuffer setString:@""];
        return;
    }

    if ([name isEqualToString:@"segmenttemplate"]) {
        if (_currentRep && _openTemplate) {
            _currentRep.mediaTemplate = _openTemplate[@"media"];
            _currentRep.mapTemplate = _openTemplate[@"initialization"];
            if (_openTemplate[@"startNumber"]) {
                _currentRep.startNumber = [_openTemplate[@"startNumber"] integerValue];
                _currentRep.startNumberSpecified = YES;
            }
            if (_openTemplate[@"timescale"]) _currentRep.timescale = [_openTemplate[@"timescale"] doubleValue];
            if (_openTemplate[@"duration"]) _currentRep.duration = [_openTemplate[@"duration"] doubleValue];
            [_currentRep.timeline addObjectsFromArray:_openTemplate[@"timeline"]];
        }
        _openTemplate = nil;
        return;
    }

    if ([name isEqualToString:@"segmenttimeline"]) { _inTimeline = NO; return; }

    if ([name isEqualToString:@"segmentlist"]) {
        if (_currentRep && _openList) {
            _currentRep.listInit = _openList[@"initialization"];
            _currentRep.listInitRange = _openList[@"initRange"];
            _currentRep.listHasInit = [_openList[@"hasInit"] boolValue];
            [_currentRep.listURLs addObjectsFromArray:_openList[@"urls"]];
        }
        _openList = nil;
        return;
    }

    if ([name isEqualToString:@"segmentbase"]) {
        if (_currentRep && _openBase) [self applySegmentBase:_openBase to:_currentRep];
        _openBase = nil;
        return;
    }

    if ([name isEqualToString:@"representation"]) {
        if (_currentRep) {
            _currentRep.base = _baseStack.lastObject;
            _currentRep.hasBase = [_baseHasURL.lastObject boolValue];
            NSString *kind = _currentRep.addressingKind ?: _setKind ?: _periodKind;
            BOOL sameSet = !_setKind || [_setKind isEqualToString:kind];
            NSMutableArray<NSDictionary *> *parents = [NSMutableArray array];
            if (sameSet && _setKind) {
                NSDictionary *parent = [kind isEqualToString:@"template"] ? _setTemplate :
                                       [kind isEqualToString:@"list"] ? _setList : _setBase;
                if (parent) [parents addObject:parent];
            }
            // Switching addressing modes at an inner level terminates the old
            // inheritance chain, rather than mixing a template with a list.
            if (sameSet && [_periodKind isEqualToString:kind]) {
                NSDictionary *parent = [kind isEqualToString:@"template"] ? _periodTemplate :
                                       [kind isEqualToString:@"list"] ? _periodList : _periodBase;
                if (parent) [parents addObject:parent];
            }
            if ([kind isEqualToString:@"template"]) {
                [_currentRep.listURLs removeAllObjects];
                _currentRep.listHasInit = NO;
                _currentRep.mapStart = -1;
                for (NSDictionary *parent in parents) {
                    if (!_currentRep.mediaTemplate.length) _currentRep.mediaTemplate = parent[@"media"];
                    if (!_currentRep.mapTemplate.length) _currentRep.mapTemplate = parent[@"initialization"];
                    if (!_currentRep.startNumberSpecified && parent[@"startNumber"]) {
                        _currentRep.startNumber = [parent[@"startNumber"] integerValue];
                        _currentRep.startNumberSpecified = YES;
                    }
                    if (_currentRep.timescale <= 0 && parent[@"timescale"]) _currentRep.timescale = [parent[@"timescale"] doubleValue];
                    if (_currentRep.duration <= 0 && parent[@"duration"]) _currentRep.duration = [parent[@"duration"] doubleValue];
                    if (!_currentRep.timeline.count) [_currentRep.timeline addObjectsFromArray:parent[@"timeline"] ?: @[]];
                }
            } else if ([kind isEqualToString:@"list"]) {
                _currentRep.mediaTemplate = nil;
                _currentRep.mapTemplate = nil;
                _currentRep.mapStart = -1;
                for (NSDictionary *parent in parents) {
                    if (!_currentRep.listHasInit && [parent[@"hasInit"] boolValue]) {
                        _currentRep.listInit = parent[@"initialization"];
                        _currentRep.listInitRange = parent[@"initRange"];
                        _currentRep.listHasInit = YES;
                    }
                    if (!_currentRep.listURLs.count) [_currentRep.listURLs addObjectsFromArray:parent[@"urls"] ?: @[]];
                }
            } else if ([kind isEqualToString:@"base"]) {
                _currentRep.mediaTemplate = nil;
                [_currentRep.listURLs removeAllObjects];
                for (NSDictionary *parent in parents) {
                    if (_currentRep.mapStart < 0) [self applySegmentBase:parent to:_currentRep];
                }
            }
            _currentRep.isVideo = [self repLooksLikeVideo:_currentRep];
            _currentRep.isAudio = !_currentRep.isVideo && [self repLooksLikeAudio:_currentRep];
            [self.representations addObject:_currentRep];
        }
        _currentRep = nil;
        [self popBaseScope];
        return;
    }

    if ([name isEqualToString:@"adaptationset"]) {
        _inAdaptationSet = NO;
        [self popBaseScope];
        return;
    }
    if ([name isEqualToString:@"period"]) {
        _inPeriod = NO;
        [self popBaseScope];
        return;
    }
}

- (void)applySegmentBase:(NSDictionary *)b to:(MVMPDRepresentation *)rep {
    NSString *range = b[@"initialization"];
    if (![range isKindOfClass:NSString.class] || !range.length) return;
    NSScanner *scanner = [NSScanner scannerWithString:range];
    long long first = 0, last = 0;
    if (![scanner scanLongLong:&first] || ![scanner scanString:@"-" intoString:nil] ||
        ![scanner scanLongLong:&last] || !scanner.isAtEnd || first < 0 || last < first || last == LLONG_MAX) return;
    rep.mapStart = first;
    rep.mapLength = last - first + 1;
}

/// AdaptationSet attributes are common in real MPDs; codecs may be a list.
- (BOOL)repLooksLikeVideo:(MVMPDRepresentation *)rep {
    NSString *kind = rep.contentType.lowercaseString;
    NSString *mime = rep.mimeType.lowercaseString;
    if ([kind isEqualToString:@"video"] || [mime hasPrefix:@"video/"]) return YES;
    if ([kind isEqualToString:@"audio"] || [mime hasPrefix:@"audio/"]) return NO;
    for (NSString *entry in [rep.codecs.lowercaseString componentsSeparatedByString:@","]) {
        NSString *codec = [entry stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([codec hasPrefix:@"avc"] || [codec hasPrefix:@"hvc"] || [codec hasPrefix:@"hev"] ||
            [codec hasPrefix:@"vp0"] || [codec hasPrefix:@"vp9"] || [codec hasPrefix:@"av01"]) return YES;
    }
    return NO;
}

- (BOOL)repLooksLikeAudio:(MVMPDRepresentation *)rep {
    NSString *kind = rep.contentType.lowercaseString;
    NSString *mime = rep.mimeType.lowercaseString;
    if ([kind isEqualToString:@"audio"] || [mime hasPrefix:@"audio/"]) return YES;
    for (NSString *entry in [rep.codecs.lowercaseString componentsSeparatedByString:@","]) {
        NSString *codec = [entry stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([codec hasPrefix:@"mp4a"] || [codec hasPrefix:@"ac-3"] || [codec hasPrefix:@"ec-3"] ||
            [codec hasPrefix:@"opus"] || [codec hasPrefix:@"vorbis"]) return YES;
    }
    return NO;
}

- (NSString *)absoluteURL:(NSString *)url base:(NSString *)base {
    if (!url.length) return base;
    if ([url hasPrefix:@"http://"] || [url hasPrefix:@"https://"]) return url;
    return [[NSURL URLWithString:url relativeToURL:[NSURL URLWithString:base]] absoluteString];
}

/// ISO-8601 duration ("PT1H2M3.5S") into seconds, 0 when unparsable.
- (double)secondsFromISO8601Duration:(NSString *)text {
    if (!text.length) return 0;
    double total = 0, number = 0, fraction = 0, fractionScale = 0;
    BOOL inTime = NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == 'T') { inTime = YES; continue; }
        if (c == 'P') continue;
        if (c >= '0' && c <= '9') {
            if (fractionScale > 0) { fraction += (c - '0') * fractionScale; fractionScale /= 10; }
            else { number = number * 10 + (c - '0'); }
            continue;
        }
        if (c == '.') { fraction = 0; fractionScale = 0.1; continue; }
        if (!inTime) { number = 0; fraction = 0; fractionScale = 0; continue; }
        double value = number + fraction;
        if (c == 'H') total += value * 3600;
        else if (c == 'M') total += value * 60;
        else if (c == 'S') total += value;
        number = 0; fraction = 0; fractionScale = 0;
    }
    return total;
}

@end

#pragma mark - Engine

@implementation MVMPDDownloader {
    NSMutableDictionary<NSString *, MVMPDJob *> *_jobs;
}

+ (instancetype)shared {
    static MVMPDDownloader *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVMPDDownloader new]; });
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
        MVMPDJob *job = _jobs[task.identifier];
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
    MVMPDJob *job = [MVMPDJob new];
    job.task = task;
    job.progressBlock = progress;
    job.finishedBlock = finished;
    job.failedBlock = failed;
    job.runToken = NSUUID.UUID.UUIDString;
    (void)[self segmentPathForJob:job index:-1]; // create a stable base before background work
    task.doneBytes = 0; // DASH segments are fetched again after a restart
    task.totalBytes = 0;
    @synchronized (self) { _jobs[task.identifier] = job; }
    if (progress) progress(task); // persist the base path before the first request
    [self fetchManifestForJob:job];
}

- (void)pauseTask:(MVDownloadTask *)task {
    MVMPDJob *job = nil;
    @synchronized (self) {
        job = _jobs[task.identifier];
        if (job) { job.paused = YES; [_jobs removeObjectForKey:task.identifier]; }
    }
    if (!job) return;
    [job.requests cancel];
    MVLogInfo(@"dash: paused %@ at %lld bytes", task.title, job.doneBytes);
}

- (void)cancelTask:(MVDownloadTask *)task {
    MVMPDJob *job;
    @synchronized (self) {
        job = _jobs[task.identifier];
        if (job) { job.cancelled = YES; [_jobs removeObjectForKey:task.identifier]; }
    }
    [job.requests cancel];
}

- (BOOL)isCurrentJob:(MVMPDJob *)job {
    @synchronized (self) {
        return _jobs[job.task.identifier] == job && !job.paused && !job.cancelled;
    }
}

#pragma mark - Manifest

- (void)fetchManifestForJob:(MVMPDJob *)job {
    NSString *url = job.task.url;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *headers = [MVMediaProbe headersForURL:url referer:job.task.referer];
        NSError *error = nil;
        NSData *data = [self syncGet:url headers:headers error:&error group:job.requests];
        if (!data.length) {
            [self failJob:job message:error.localizedDescription ?: [MVLang t:@"Could not open the stream"]];
            return;
        }

        MVMPDParser *parser = [[MVMPDParser alloc] initWithURL:url];
        if (![parser parse:data]) {
            [self failJob:job message:[MVLang t:@"Could not open the stream"]];
            return;
        }
        if (parser.isLive) {
            [self failJob:job message:[MVLang t:@"Live streams can't be downloaded"]];
            return;
        }
        if (parser.isProtected) {
            [self failJob:job message:[MVLang t:@"This stream is protected and can't be downloaded"]];
            return;
        }

        if (parser.periodCount != 1) {
            [self failJob:job message:[MVLang t:@"Multiple DASH periods are not supported"]];
            return;
        }
        BOOL hasVideo = NO, hasAudio = NO;
        for (MVMPDRepresentation *candidate in parser.representations) {
            hasVideo |= candidate.isVideo;
            hasAudio |= candidate.isAudio;
        }
        MVMPDRepresentation *video = [self bestRepresentationIn:parser.representations audio:NO];
        MVMPDRepresentation *audio = [self bestRepresentationIn:parser.representations audio:YES];
        if ((hasVideo && !video) || (hasAudio && !audio)) {
            [self failJob:job message:[MVLang t:@"Unsupported DASH media format"]];
            return;
        }
        MVMPDRepresentation *primary = video ?: audio;
        if (!primary) {
            [self failJob:job message:[MVLang t:@"Could not open the stream"]];
            return;
        }
        job.audioOnly = !video;
        double period = parser.periodDuration > 0 ? parser.periodDuration : parser.presentationDuration;
        if (![self buildSegmentsFor:primary period:period into:job]) {
            [self failJob:job message:[MVLang t:@"Could not open the stream"]];
            return;
        }
        job.primarySegmentCount = job.segments.count;
        if (video && audio) {
            MVMPDJob *sound = [MVMPDJob new];
            sound.task = job.task;
            if (![self buildSegmentsFor:audio period:period into:sound]) {
                [self failJob:job message:[MVLang t:@"Could not open the stream"]];
                return;
            }
            job.hasSeparateAudio = YES;
            job.audioMapSegment = sound.mapSegment;
            job.audioMapSegment.index = -2;
            for (MVMPDSegment *segment in sound.segments) {
                segment.index += (NSInteger)job.primarySegmentCount;
                [job.segments addObject:segment];
            }
        }

        NSMutableArray<NSDictionary *> *initializations = [NSMutableArray array];
        NSMutableArray<MVMPDSegment *> *maps = [NSMutableArray array];
        if (job.mapSegment) [maps addObject:job.mapSegment];
        if (job.audioMapSegment) [maps addObject:job.audioMapSegment];
        for (MVMPDSegment *segment in maps) {
            if (job.paused || job.cancelled) return;
            NSMutableDictionary *initHeaders =
                [[MVMediaProbe headersForURL:segment.url referer:job.task.resourceContextURL] mutableCopy];
            if (segment.byteStart >= 0) {
                initHeaders[@"Range"] = [NSString stringWithFormat:@"bytes=%lld-%lld", segment.byteStart,
                                         segment.byteStart + segment.byteLength - 1];
            }
            NSError *initError = nil;
            NSData *initData = [self syncGet:segment.url headers:initHeaders error:&initError group:job.requests];
            if (!initData.length) {
                [self failJob:job message:initError.localizedDescription ?: [MVLang t:@"Could not open the stream"]];
                return;
            }
            [initializations addObject:@{@"segment": segment, @"data": initData}];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isCurrentJob:job]) return;
            for (NSDictionary *item in initializations) {
                MVMPDSegment *segment = item[@"segment"];
                if (![self writeSegment:item[@"data"] index:segment.index job:job]) {
                    [self failJob:job message:[MVLang t:@"Could not save the file"]];
                    return;
                }
            }
            job.task.phase = [MVLang t:@"Downloading segments"];
            [self pumpJob:job];
        });
    });
}

/// Prefer the highest-bandwidth MP4 representation of each kind. WebM/Matroska
/// are not fMP4 and must not be presented as a successfully saved MP4.
- (nullable MVMPDRepresentation *)bestRepresentationIn:(NSArray<MVMPDRepresentation *> *)reps audio:(BOOL)audio {
    MVMPDRepresentation *best = nil;
    for (MVMPDRepresentation *rep in reps) {
        if (audio ? !rep.isAudio : !rep.isVideo) continue;
        NSString *mime = rep.mimeType.lowercaseString;
        if ([mime containsString:@"webm"] || [mime containsString:@"matroska"]) continue;
        if (!best || rep.bandwidth > best.bandwidth) best = rep;
    }
    return best;
}

/// Turns a representation's addressing into a concrete segment list.
- (BOOL)buildSegmentsFor:(MVMPDRepresentation *)rep period:(double)period into:(MVMPDJob *)job {
    NSString *base = rep.base.length ? rep.base : job.task.url;

    // SegmentList: an explicit list of media URLs.
    if (rep.listURLs.count) {
        if (rep.listURLs.count > (NSUInteger)kMaxSegments) return NO;
        if (rep.listHasInit || rep.listInit.length) {
            long long start = -1, length = -1;
            if (rep.listInitRange.length && ![self parseRange:rep.listInitRange start:&start length:&length]) return NO;
            job.mapSegment = [self segmentForURL:[self absoluteURL:rep.listInit ?: @"" base:base]
                                           index:-1 start:start length:length];
        }
        NSInteger index = 0;
        for (NSDictionary *entry in rep.listURLs) {
            NSString *range = entry[@"range"];
            long long start = -1, length = -1;
            if (range.length && ![self parseRange:range start:&start length:&length]) return NO;
            [job.segments addObject:[self segmentForURL:[self absoluteURL:entry[@"url"] base:base]
                                                  index:index++ start:start length:length]];
        }
        return job.segments.count > 0;
    }

    // SegmentTemplate: build the URLs from the template.
    if (rep.mediaTemplate.length) {
        if (rep.startNumber < 0 || rep.startNumber == NSIntegerMax) return NO;
        if (rep.mapTemplate.length) {
            NSString *initialization = [self fillTemplate:rep.mapTemplate rep:rep number:rep.startNumber time:0];
            if (!initialization.length) return NO;
            job.mapSegment = [self segmentForURL:initialization index:-1 start:-1 length:-1];
        }
        NSInteger number = rep.startNumber;
        long long time = 0;
        if (rep.timeline.count) {
            for (NSDictionary *entry in rep.timeline) {
                long long t = [entry[@"t"] longLongValue];
                long long d = [entry[@"d"] longLongValue];
                NSInteger r = [entry[@"r"] integerValue];
                // An unbounded repeat needs the next Period/timeline boundary;
                // do not silently emit an incomplete stream.
                if (r < 0 || d <= 0) return NO;
                if (t >= 0) time = t;
                for (NSInteger i = 0; i <= r; i++) {
                    if ((NSInteger)job.segments.count >= kMaxSegments || number == NSIntegerMax || time > LLONG_MAX - d) return NO;
                    NSString *url = [self fillTemplate:rep.mediaTemplate rep:rep number:number time:time];
                    if (!url.length) return NO;
                    [job.segments addObject:[self segmentForURL:url index:job.segments.count start:-1 length:-1]];
                    number++;
                    time += d;
                }
            }
            return job.segments.count > 0;
        }
        if (rep.duration > 0 && period > 0) {
            double timescale = rep.timescale > 0 ? rep.timescale : 1; // DASH default
            if (!isfinite(period) || !isfinite(timescale) || !isfinite(rep.duration) ||
                rep.duration >= (double)LLONG_MAX || floor(rep.duration) != rep.duration) return NO;
            double countValue = ceil(period / (rep.duration / timescale));
            if (!isfinite(countValue) || countValue < 1 || countValue > kMaxSegments) return NO;
            NSInteger count = (NSInteger)countValue;
            long long step = (long long)rep.duration;
            for (NSInteger i = 0; i < count; i++) {
                if (number == NSIntegerMax || time > LLONG_MAX - step) return NO;
                NSString *url = [self fillTemplate:rep.mediaTemplate rep:rep number:number time:time];
                if (!url.length) return NO;
                [job.segments addObject:[self segmentForURL:url index:job.segments.count start:-1 length:-1]];
                number++;
                time += step;
            }
            return job.segments.count > 0;
        }
        return NO;   // a template with no way to know the count is not downloadable
    }

    // SegmentBase / a bare BaseURL: one resource holds the whole stream. The
    // base must have been declared, otherwise this is a manifest with no media
    // addressing and there is nothing to download.
    if (rep.hasBase) {
        // Fetching the entire resource already includes its initialization box;
        // prepending SegmentBase's init range again would corrupt the file.
        [job.segments addObject:[self segmentForURL:base index:0 start:-1 length:-1]];
        return YES;
    }

    return NO;
}

- (BOOL)parseRange:(NSString *)range start:(long long *)start length:(long long *)length {
    NSScanner *scanner = [NSScanner scannerWithString:range];
    long long first = 0, last = 0;
    if (![scanner scanLongLong:&first] || ![scanner scanString:@"-" intoString:nil] ||
        ![scanner scanLongLong:&last] || !scanner.isAtEnd || first < 0 || last < first || last == LLONG_MAX) return NO;
    *start = first;
    *length = last - first + 1;
    return YES;
}

- (MVMPDSegment *)segmentForURL:(NSString *)url index:(NSInteger)index start:(long long)start length:(long long)length {
    MVMPDSegment *segment = [MVMPDSegment new];
    segment.index = index;
    segment.url = url;
    segment.byteStart = start;
    segment.byteLength = length;
    return segment;
}

/// Substitutes the DASH template placeholders. `$Number$` also accepts the
/// `%0Nd` width form; `$Time$`, `$Bandwidth$` and `$RepresentationID$` are the
/// other placeholders a media template uses.
- (NSString *)fillTemplate:(NSString *)template rep:(MVMPDRepresentation *)rep number:(NSInteger)number time:(long long)time {
    if (template.length > 8192) return nil;
    NSMutableString *out = [NSMutableString string];
    NSUInteger i = 0;
    while (i < template.length) {
        if ([template characterAtIndex:i] != '$') {
            NSRange remaining = NSMakeRange(i, template.length - i);
            NSRange next = [template rangeOfString:@"$" options:0 range:remaining];
            NSUInteger end = next.location == NSNotFound ? template.length : next.location;
            [out appendString:[template substringWithRange:NSMakeRange(i, end - i)]];
            i = end;
            continue;
        }
        if (i + 1 < template.length && [template characterAtIndex:i + 1] == '$') {
            [out appendString:@"$"];
            i += 2;
            continue;
        }
        NSRange tail = NSMakeRange(i + 1, template.length - i - 1);
        NSRange close = [template rangeOfString:@"$" options:0 range:tail];
        if (close.location == NSNotFound) return nil;
        NSString *token = [template substringWithRange:NSMakeRange(i + 1, close.location - i - 1)];
        NSString *value = nil;
        if ([token isEqualToString:@"RepresentationID"]) {
            value = rep.repID.length ? rep.repID : nil;
        } else if ([token isEqualToString:@"Bandwidth"]) {
            if (!isfinite(rep.bandwidth) || rep.bandwidth < 0 || rep.bandwidth >= (double)LLONG_MAX) return nil;
            value = [NSString stringWithFormat:@"%lld", (long long)rep.bandwidth];
        } else if ([token isEqualToString:@"Time"]) {
            value = [NSString stringWithFormat:@"%lld", time];
        } else if ([token isEqualToString:@"Number"]) {
            value = [NSString stringWithFormat:@"%ld", (long)number];
        } else if ([token hasPrefix:@"Number%0"] && [token hasSuffix:@"d"] && token.length > 9) {
            NSString *widthText = [token substringWithRange:NSMakeRange(8, token.length - 9)];
            NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
            if ([widthText rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return nil;
            NSInteger width = widthText.integerValue;
            if (width < 1 || width > 20) return nil;
            value = [NSString stringWithFormat:@"%0*ld", (int)width, (long)number];
        }
        if (!value) return nil; // do not request an unsupported placeholder literally
        [out appendString:value];
        if (out.length > 8192) return nil;
        i = NSMaxRange(close);
    }
    return [self absoluteURL:out base:rep.base ?: @""];
}

- (NSString *)absoluteURL:(NSString *)url base:(NSString *)base {
    if (!url.length) return base;
    if ([url hasPrefix:@"http://"] || [url hasPrefix:@"https://"]) return url;
    return [[NSURL URLWithString:url relativeToURL:[NSURL URLWithString:base]] absoluteString];
}

#pragma mark - Segments

- (void)pumpJob:(MVMPDJob *)job {
    if (![self isCurrentJob:job] || job.finishing) return;
    while (job.inFlight < (NSUInteger)kMaxParallelSegments) {
        MVMPDSegment *next = nil;
        for (MVMPDSegment *segment in job.segments) {
            if (!segment.done && !segment.inFlight && segment.retries < kMaxSegmentRetries) { next = segment; break; }
        }
        if (!next) break;
        [self fetchSegment:next job:job];
    }
    if (job.inFlight > 0) return;
    BOOL pending = NO;
    for (MVMPDSegment *segment in job.segments) {
        if (segment.done) continue;
        if (segment.retries >= kMaxSegmentRetries) {
            [self failJob:job message:[MVLang t:@"Download incomplete"]];
            return;
        }
        pending = YES;
    }
    if (!pending) [self finishJob:job];
}

- (void)fetchSegment:(MVMPDSegment *)segment job:(MVMPDJob *)job {
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
        dispatch_async(dispatch_get_main_queue(), ^{
            job.inFlight--;
            segment.inFlight = NO;
            if (![self isCurrentJob:job] || job.finishing) return;
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
                MVLogWarn(@"dash: segment %ld failed (%@), retry %ld", (long)segment.index,
                          error.localizedDescription, (long)segment.retries);
            }
            [self pumpJob:job];
        });
    });
}

- (BOOL)writeSegment:(NSData *)data index:(NSInteger)index job:(MVMPDJob *)job {
    NSString *path = [self segmentPathForJob:job index:index];
    if (![MVFileProtection isSafePartialItemAtPath:path] ||
        [MVFileProtection path:path conflictsWithPaths:[MVFileProtection pathsExcludingTask:job.task record:nil]]) return NO;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                   withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    return [data writeToFile:path atomically:YES];
}

#pragma mark - Finish

- (NSString *)runPathForJob:(MVMPDJob *)job kind:(NSString *)kind extension:(NSString *)extension {
    return [NSString stringWithFormat:@"%@.%@-%@.%@", job.tempPath, kind, job.runToken, extension];
}

- (void)removeRunOutputsForJob:(MVMPDJob *)job {
    NSArray *protected = [MVFileProtection pathsExcludingTask:job.task record:nil];
    [MVFileProtection removePartialItemAtPath:[self runPathForJob:job kind:@"primary" extension:(job.audioOnly ? @"m4a" : @"mp4")]
                                  protecting:protected];
    [MVFileProtection removePartialItemAtPath:[self runPathForJob:job kind:@"audio" extension:@"m4a"] protecting:protected];
    [MVFileProtection removePartialItemAtPath:[self runPathForJob:job kind:@"mux" extension:@"mp4"] protecting:protected];
}

/// Concatenate a single fMP4 track into a run-specific temporary file. Source
/// parts remain intact until the current run has published successfully.
- (BOOL)joinSegments:(NSArray<MVMPDSegment *> *)segments map:(MVMPDSegment *)map
                job:(MVMPDJob *)job to:(NSString *)path {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:path error:nil];
    if (![fm createFileAtPath:path contents:nil attributes:nil]) return NO;
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!out || !segments.count) {
        [out closeFile];
        [fm removeItemAtPath:path error:nil];
        return NO;
    }
    NSMutableArray<MVMPDSegment *> *ordered = [NSMutableArray array];
    if (map) [ordered addObject:map];
    [ordered addObjectsFromArray:segments];
    BOOL ok = YES;
    for (MVMPDSegment *segment in ordered) {
        if (segment != map && !segment.done) { ok = NO; break; }
        NSString *source = [self segmentPathForJob:job index:segment.index];
        NSDictionary *attrs = [fm attributesOfItemAtPath:source error:nil];
        if (!attrs || [attrs[NSFileSize] longLongValue] <= 0) { ok = NO; break; }
        NSFileHandle *in = [NSFileHandle fileHandleForReadingAtPath:source];
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
    if (!ok) [fm removeItemAtPath:path error:nil];
    return ok;
}

- (void)finishJob:(MVMPDJob *)job {
    if (job.finishing || ![self isCurrentJob:job]) return;
    job.finishing = YES;
    job.task.phase = [MVLang t:@"Joining segments"];
    if (job.progressBlock) job.progressBlock(job.task);

    NSArray<MVMPDSegment *> *primary = [job.segments subarrayWithRange:NSMakeRange(0, job.primarySegmentCount)];
    NSArray<MVMPDSegment *> *audio = [job.segments subarrayWithRange:NSMakeRange(job.primarySegmentCount,
                                                      job.segments.count - job.primarySegmentCount)];
    NSString *primaryPath = [self runPathForJob:job kind:@"primary" extension:(job.audioOnly ? @"m4a" : @"mp4")];
    NSString *audioPath = [self runPathForJob:job kind:@"audio" extension:@"m4a"];
    NSString *muxPath = [self runPathForJob:job kind:@"mux" extension:@"mp4"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = [self joinSegments:primary map:job.mapSegment job:job to:primaryPath];
        if (ok) ok = job.audioOnly ? [MVMediaConverter hasAudioTrack:primaryPath] : [MVMediaConverter hasVideoTrack:primaryPath];
        if (ok && job.hasSeparateAudio) {
            ok = [self joinSegments:audio map:job.audioMapSegment job:job to:audioPath] &&
                 [MVMediaConverter hasAudioTrack:audioPath];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isCurrentJob:job]) { [self removeRunOutputsForJob:job]; return; }
            if (!ok) {
                [self failJob:job message:[MVLang t:@"Could not open the stream"]];
                return;
            }
            if (!job.hasSeparateAudio) {
                [self publishJob:job path:primaryPath extension:(job.audioOnly ? @"m4a" : @"mp4")];
                return;
            }
            job.task.phase = [MVLang t:@"Merging…"];
            if (job.progressBlock) job.progressBlock(job.task);
            [MVMediaConverter muxVideo:primaryPath audio:audioPath to:muxPath completion:^(BOOL merged, NSString *error) {
                if (![self isCurrentJob:job]) { [self removeRunOutputsForJob:job]; return; }
                if (!merged) {
                    [self failJob:job message:error ?: [MVLang t:@"Merge failed"]];
                    return;
                }
                [self publishJob:job path:muxPath extension:@"mp4"];
            }];
        });
    });
}

- (void)publishJob:(MVMPDJob *)job path:(NSString *)path extension:(NSString *)extension {
    if (![self isCurrentJob:job]) { [self removeRunOutputsForJob:job]; return; }
    MVDownloadTask *task = job.task;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *directory = [MVPaths directoryForCategory:task.category];
    NSString *base = task.suggestedFilename.length ? task.suggestedFilename.stringByDeletingPathExtension : @"stream";
    NSString *name = [base stringByAppendingPathExtension:extension];
    NSString *destination = [MVPaths uniquePathInDirectory:directory filename:name];
    if (![fm moveItemAtPath:path toPath:destination error:nil]) {
        [self failJob:job message:[MVLang t:@"Could not save the file"]];
        return;
    }
    [self removeRunOutputsForJob:job];
    [MVMPDDownloader removePartFilesForTask:task];
    long long size = [[fm attributesOfItemAtPath:destination error:nil][NSFileSize] longLongValue];
    task.path = destination;
    task.tempPath = nil;
    task.phase = nil;
    task.speed = 0;
    task.eta = 0;
    task.totalBytes = size;
    task.doneBytes = size;
    @synchronized (self) { if (_jobs[task.identifier] == job) [_jobs removeObjectForKey:task.identifier]; }
    MVLogInfo(@"dash: finished %@ (%lld bytes) -> %@", task.title, size, destination);
    if (job.finishedBlock) job.finishedBlock(task);
}

#pragma mark - Failure

- (void)failJob:(MVMPDJob *)job message:(NSString *)message {
    void (^finishFailure)(void) = ^{
        if (![self isCurrentJob:job]) return;
        @synchronized (self) { if (_jobs[job.task.identifier] == job) [_jobs removeObjectForKey:job.task.identifier]; }
        [job.requests cancel];
        [self removeRunOutputsForJob:job];
        MVLogError(@"dash: failed %@: %@", job.task.title, message);
        if (job.failedBlock) job.failedBlock(job.task, message);
    };
    if (NSThread.isMainThread) finishFailure();
    else dispatch_async(dispatch_get_main_queue(), finishFailure);
}

#pragma mark - Networking

/// A blocking GET on a background thread, matching the HLS engine: DASH is a
/// sequence of small requests and the parallelism lives in the segment pump.
- (NSData *)syncGet:(NSString *)url headers:(NSDictionary<NSString *, NSString *> *)headers error:(NSError **)error {
    return [self syncGet:url headers:headers error:error group:nil];
}

- (NSData *)syncGet:(NSString *)url headers:(NSDictionary<NSString *, NSString *> *)headers
              error:(NSError **)error group:(MVRequestGroup *)group {
    NSURL *target = [NSURL URLWithString:url];
    if (!target || ![@[@"http", @"https"] containsObject:target.scheme.lowercaseString]) {
        if (error) *error = [NSError errorWithDomain:@"MVMPD" code:-1
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
    long long requestedStart = -1, requestedLength = -1;
    if (rangeHeader.length && (![rangeHeader hasPrefix:@"bytes="] ||
        ![self parseRange:[rangeHeader substringFromIndex:6] start:&requestedStart length:&requestedLength])) {
        if (error) *error = [NSError errorWithDomain:@"MVMPD" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: [MVLang t:@"Server did not honor the requested byte range"]}];
        return nil;
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
            resultError = [NSError errorWithDomain:@"MVMPD" code:http.statusCode
                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]}];
        } else if (rangeHeader.length) {
            NSString *contentRange = [http valueForHTTPHeaderField:@"Content-Range"];
            NSString *encoding = [http valueForHTTPHeaderField:@"Content-Encoding"];
            MVContentRange parsed;
            if (http.statusCode != 206 ||
                (encoding.length && [encoding caseInsensitiveCompare:@"identity"] != NSOrderedSame) ||
                !MVParseContentRange(contentRange.UTF8String, &parsed) ||
                !MVContentRangeMatches(&parsed, requestedStart, requestedStart + requestedLength - 1, -1) ||
                (long long)data.length != requestedLength) {
                resultError = [NSError errorWithDomain:@"MVMPD" code:-1
                    userInfo:@{NSLocalizedDescriptionKey: [MVLang t:@"Server did not honor the requested byte range"]}];
            } else result = data;
        } else if (http.statusCode == 200) result = data;
        else resultError = [NSError errorWithDomain:@"MVMPD" code:http.statusCode
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
        if (error) *error = [NSError errorWithDomain:@"MVMPD" code:-1
                                           userInfo:@{NSLocalizedDescriptionKey: [MVLang t:@"Connection timed out"]}];
        return nil; // completion may still run after cancel
    }
    if (error) *error = resultError;
    return result;
}

#pragma mark - Paths

- (NSString *)segmentPathForJob:(MVMPDJob *)job index:(NSInteger)index {
    NSString *base = job.tempPath;
    if (!base.length) {
        base = job.task.tempPath;
        if (!base.length) {
            NSString *directory = [MVPaths directoryForCategory:job.task.category];
            NSString *name = [MVPaths sanitizeFilename:job.task.suggestedFilename ?: job.task.url.lastPathComponent];
            if (!name.length) name = @"stream";
            base = [directory stringByAppendingPathComponent:
                    [NSString stringWithFormat:@".%@.%@.dash", job.task.identifier, name]];
            job.task.tempPath = base;
        }
        job.tempPath = base;
    }
    return [NSString stringWithFormat:@"%@.seg%ld", base, (long)index];
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
        if ([suffix hasPrefix:@"seg"] || [suffix hasPrefix:@"primary-"] || [suffix hasPrefix:@"audio-"] ||
            [suffix hasPrefix:@"mux-"] || [suffix isEqualToString:@"joined"] || [suffix isEqualToString:@"mp4"]) {
            [MVFileProtection removePartialItemAtPath:[directory stringByAppendingPathComponent:name] protecting:protected];
        }
    }
}

@end
