#import "MVMPDDownloader.h"
#import "MVPaths.h"
#import "MVMediaProbe.h"
#import "MVLang.h"
#import "MVLog.h"

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
@end
@implementation MVMPDSegment
@end

/// One `<Representation>`, flattened to the addressing forms a downloader uses.
@interface MVMPDRepresentation : NSObject
@property (nonatomic, copy) NSString *repID;
@property (nonatomic) double bandwidth;
@property (nonatomic, copy, nullable) NSString *mimeType;
@property (nonatomic, copy, nullable) NSString *codecs;
/// The base URL this representation's relative URLs resolve against.
@property (nonatomic, copy, nullable) NSString *base;
/// SegmentTemplate addressing.
@property (nonatomic, copy, nullable) NSString *mediaTemplate;
@property (nonatomic, copy, nullable) NSString *initTemplate;
@property (nonatomic) NSInteger startNumber;
@property (nonatomic) double timescale;
@property (nonatomic) double duration;
/// SegmentTimeline entries, each @{@"t": NSNumber, @"d": NSNumber, @"r": NSNumber}.
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *timeline;
/// SegmentList addressing.
@property (nonatomic, copy, nullable) NSString *listInit;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *listURLs;   ///< @{url, range}
/// SegmentBase addressing: the init byte range inside the single resource.
@property (nonatomic) long long initStart;
@property (nonatomic) long long initLength;
/// YES when a `<BaseURL>` was declared for this representation (or its
/// AdaptationSet), so a single-resource download has a real media URL.
@property (nonatomic) BOOL hasBase;
@property (nonatomic) BOOL isVideo;
@end
@implementation MVMPDRepresentation
- (instancetype)init {
    if ((self = [super init])) {
        _timeline = [NSMutableArray array];
        _listURLs = [NSMutableArray array];
        _startNumber = 1;
        _initStart = -1;
        _initLength = -1;
    }
    return self;
}
@end

/// One running DASH download.
@interface MVMPDJob : NSObject
@property (nonatomic, strong) MVDownloadTask *task;
@property (nonatomic, strong) NSMutableArray<MVMPDSegment *> *segments;
@property (nonatomic, strong, nullable) MVMPDSegment *mapSegment;
@property (nonatomic) BOOL paused;
@property (nonatomic) BOOL cancelled;
@property (nonatomic) BOOL finishing;
@property (nonatomic) NSUInteger inFlight;
@property (nonatomic) long long doneBytes;
@property (nonatomic, copy, nullable) void (^progressBlock)(MVDownloadTask *task);
@property (nonatomic, copy, nullable) void (^finishedBlock)(MVDownloadTask *task);
@property (nonatomic, copy, nullable) void (^failedBlock)(MVDownloadTask *task, NSString *message);
@end
@implementation MVMPDJob
- (instancetype)init {
    if ((self = [super init])) _segments = [NSMutableArray array];
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
- (instancetype)initWithURL:(NSString *)url;
- (BOOL)parse:(NSData *)data;
@end

@implementation MVMPDParser {
    NSMutableArray<NSString *> *_baseStack;
    NSMutableString *_textBuffer;
    MVMPDRepresentation *_currentRep;
    // Segment addressing inherited from an enclosing AdaptationSet.
    NSMutableDictionary *_setTemplate;
    NSMutableDictionary *_setList;
    NSMutableDictionary *_setBase;
    // The SegmentTemplate/SegmentList/SegmentBase currently open, so its
    // children (SegmentTimeline, SegmentURL) land in the right place.
    NSMutableDictionary *_openTemplate;
    NSMutableDictionary *_openList;
    NSMutableDictionary *_openBase;
    BOOL _inTimeline;
    BOOL _setHasBase;
}

- (instancetype)initWithURL:(NSString *)url {
    if ((self = [super init])) {
        _manifestURL = [url copy];
        _representations = [NSMutableArray array];
        _baseStack = [NSMutableArray arrayWithObject:url];
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
        [_baseStack addObject:_baseStack.lastObject];
        self.periodDuration = [self secondsFromISO8601Duration:attributes[@"duration"]];
        _setTemplate = nil; _setList = nil; _setBase = nil;
        return;
    }

    if ([name isEqualToString:@"adaptationset"]) {
        [_baseStack addObject:_baseStack.lastObject];
        _setTemplate = nil; _setList = nil; _setBase = nil;
        _setHasBase = NO;
        return;
    }

    if ([name isEqualToString:@"representation"]) {
        [_baseStack addObject:_baseStack.lastObject];
        MVMPDRepresentation *rep = [MVMPDRepresentation new];
        rep.repID = attributes[@"id"];
        rep.bandwidth = [attributes[@"bandwidth"] doubleValue];
        rep.mimeType = attributes[@"mimeType"];
        rep.codecs = attributes[@"codecs"];
        rep.startNumber = attributes[@"startNumber"] ? attributes[@"startNumber"].integerValue : 1;
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
        if (_currentRep) { _openTemplate = t; }
        else { _setTemplate = t; }
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
        NSMutableArray *timeline = _currentRep ? _currentRep.timeline
                                               : (_openTemplate[@"timeline"] ?: _setTemplate[@"timeline"]);
        if (timeline) [timeline addObject:entry];
        return;
    }

    if ([name isEqualToString:@"segmentlist"]) {
        NSMutableDictionary *l = [NSMutableDictionary dictionary];
        l[@"initialization"] = attributes[@"initialization"] ?: @"";
        l[@"urls"] = [NSMutableArray array];
        if (_currentRep) { _openList = l; }
        else { _setList = l; }
        return;
    }

    if ([name isEqualToString:@"segmenturl"]) {
        NSString *media = attributes[@"media"];
        if (media.length) {
            NSDictionary *entry = @{@"url": media, @"range": attributes[@"mediaRange"] ?: @""};
            NSMutableArray *urls = _currentRep ? _currentRep.listURLs
                                               : (_openList[@"urls"] ?: _setList[@"urls"]);
            if (urls) [urls addObject:entry];
        }
        return;
    }

    if ([name isEqualToString:@"segmentbase"]) {
        NSMutableDictionary *b = [NSMutableDictionary dictionary];
        b[@"initialization"] = attributes[@"initialization"] ?: @"";
        if (_currentRep) { _openBase = b; }
        else { _setBase = b; }
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
        if (text.length && _baseStack.count) {
            _baseStack[_baseStack.count - 1] = [self absoluteURL:text base:_baseStack.lastObject];
            if (_currentRep) _currentRep.hasBase = YES;
            else _setHasBase = YES;
        }
        [_textBuffer setString:@""];
        return;
    }

    if ([name isEqualToString:@"segmenttemplate"]) {
        if (_currentRep && _openTemplate) {
            _currentRep.mediaTemplate = _openTemplate[@"media"];
            _currentRep.initTemplate = _openTemplate[@"initialization"];
            if (_openTemplate[@"startNumber"]) _currentRep.startNumber = [_openTemplate[@"startNumber"] integerValue];
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
            // A representation may inherit its addressing from the AdaptationSet.
            if (!_currentRep.mediaTemplate.length && _setTemplate) {
                _currentRep.mediaTemplate = _setTemplate[@"media"];
                _currentRep.initTemplate = _setTemplate[@"initialization"];
                if (_setTemplate[@"startNumber"]) _currentRep.startNumber = [_setTemplate[@"startNumber"] integerValue];
                if (_setTemplate[@"timescale"]) _currentRep.timescale = [_setTemplate[@"timescale"] doubleValue];
                if (_setTemplate[@"duration"]) _currentRep.duration = [_setTemplate[@"duration"] doubleValue];
                [_currentRep.timeline addObjectsFromArray:_setTemplate[@"timeline"]];
            }
            if (!_currentRep.listURLs.count && [_setList[@"urls"] count]) {
                _currentRep.listInit = _setList[@"initialization"];
                [_currentRep.listURLs addObjectsFromArray:_setList[@"urls"]];
            }
            if (_currentRep.initStart < 0 && _setBase) [self applySegmentBase:_setBase to:_currentRep];
            if (_setHasBase) _currentRep.hasBase = YES;
            _currentRep.isVideo = [self repLooksLikeVideo:_currentRep];
            [self.representations addObject:_currentRep];
        }
        _currentRep = nil;
        if (_baseStack.count > 1) [_baseStack removeLastObject];
        return;
    }

    if ([name isEqualToString:@"adaptationset"] || [name isEqualToString:@"period"]) {
        if (_baseStack.count > 1) [_baseStack removeLastObject];
        return;
    }
}

- (void)applySegmentBase:(NSDictionary *)b to:(MVMPDRepresentation *)rep {
    NSString *range = b[@"initialization"];
    if (![range isKindOfClass:NSString.class] || !range.length) return;
    NSArray<NSString *> *parts = [range componentsSeparatedByString:@"-"];
    if (parts.count != 2) return;
    rep.initStart = parts[0].longLongValue;
    rep.initLength = parts[1].longLongValue - parts[0].longLongValue + 1;
}

/// YES when the representation carries video, by mimeType or codec.
- (BOOL)repLooksLikeVideo:(MVMPDRepresentation *)rep {
    NSString *mime = rep.mimeType.lowercaseString;
    if ([mime containsString:@"video"]) return YES;
    if ([mime containsString:@"audio"]) return NO;
    NSString *codecs = rep.codecs.lowercaseString;
    if ([codecs hasPrefix:@"avc"] || [codecs hasPrefix:@"hvc"] || [codecs hasPrefix:@"hev"] ||
        [codecs hasPrefix:@"vp0"] || [codecs hasPrefix:@"vp9"] || [codecs hasPrefix:@"av01"]) return YES;
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
    @synchronized (self) { _jobs[task.identifier] = job; }
    [self fetchManifestForJob:job];
}

- (void)pauseTask:(MVDownloadTask *)task {
    MVMPDJob *job = nil;
    @synchronized (self) { job = _jobs[task.identifier]; }
    if (!job) return;
    job.paused = YES;
    @synchronized (self) { [_jobs removeObjectForKey:task.identifier]; }
    MVLogInfo(@"dash: paused %@ at %lld bytes", task.title, job.doneBytes);
}

- (void)cancelTask:(MVDownloadTask *)task {
    MVMPDJob *job = nil;
    @synchronized (self) { job = _jobs[task.identifier]; }
    if (!job) return;
    job.cancelled = YES;
    @synchronized (self) { [_jobs removeObjectForKey:task.identifier]; }
}

#pragma mark - Manifest

- (void)fetchManifestForJob:(MVMPDJob *)job {
    NSString *url = job.task.url;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *headers = [MVMediaProbe headersForURL:url referer:job.task.referer];
        NSError *error = nil;
        NSData *data = [self syncGet:url headers:headers error:&error];
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

        MVMPDRepresentation *rep = [self bestRepresentationIn:parser.representations];
        if (!rep) {
            [self failJob:job message:[MVLang t:@"Could not open the stream"]];
            return;
        }

        double period = parser.periodDuration > 0 ? parser.periodDuration : parser.presentationDuration;
        if (![self buildSegmentsFor:rep period:period into:job]) {
            [self failJob:job message:[MVLang t:@"Could not open the stream"]];
            return;
        }

        if (job.mapSegment) {
            NSMutableDictionary *initHeaders =
                [[MVMediaProbe headersForURL:job.mapSegment.url referer:job.task.referer] mutableCopy];
            if (job.mapSegment.byteStart >= 0) {
                initHeaders[@"Range"] = [NSString stringWithFormat:@"bytes=%lld-%lld",
                                         job.mapSegment.byteStart,
                                         job.mapSegment.byteStart + job.mapSegment.byteLength - 1];
            }
            NSError *initError = nil;
            NSData *initData = [self syncGet:job.mapSegment.url headers:initHeaders error:&initError];
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

/// The highest-bandwidth video representation, or the highest-bandwidth
/// representation of any kind when the manifest carries no video.
- (nullable MVMPDRepresentation *)bestRepresentationIn:(NSArray<MVMPDRepresentation *> *)reps {
    MVMPDRepresentation *best = nil;
    BOOL anyVideo = NO;
    for (MVMPDRepresentation *rep in reps) if (rep.isVideo) { anyVideo = YES; break; }
    for (MVMPDRepresentation *rep in reps) {
        if (anyVideo && !rep.isVideo) continue;
        if (!best || rep.bandwidth > best.bandwidth) best = rep;
    }
    return best;
}

/// Turns a representation's addressing into a concrete segment list.
- (BOOL)buildSegmentsFor:(MVMPDRepresentation *)rep period:(double)period into:(MVMPDJob *)job {
    NSString *base = rep.base.length ? rep.base : job.task.url;

    // SegmentList: an explicit list of media URLs.
    if (rep.listURLs.count) {
        if (rep.listInit.length) {
            job.mapSegment = [self segmentForURL:[self absoluteURL:rep.listInit base:base] index:-1 start:-1 length:-1];
        }
        NSInteger index = 0;
        for (NSDictionary *entry in rep.listURLs) {
            NSString *range = entry[@"range"];
            long long start = -1, length = -1;
            if (range.length) {
                NSArray<NSString *> *parts = [range componentsSeparatedByString:@"-"];
                if (parts.count == 2) {
                    start = parts[0].longLongValue;
                    length = parts[1].longLongValue - start + 1;
                }
            }
            [job.segments addObject:[self segmentForURL:[self absoluteURL:entry[@"url"] base:base]
                                                  index:index++ start:start length:length]];
        }
        return job.segments.count > 0;
    }

    // SegmentTemplate: build the URLs from the template.
    if (rep.mediaTemplate.length) {
        if (rep.initTemplate.length) {
            job.mapSegment = [self segmentForURL:[self fillTemplate:rep.initTemplate rep:rep number:rep.startNumber time:0]
                                           index:-1 start:-1 length:-1];
        }
        NSInteger number = rep.startNumber;
        long long time = 0;
        if (rep.timeline.count) {
            for (NSDictionary *entry in rep.timeline) {
                long long t = [entry[@"t"] longLongValue];
                long long d = [entry[@"d"] longLongValue];
                NSInteger r = [entry[@"r"] integerValue];
                if (t >= 0) time = t;
                for (NSInteger i = 0; i <= r; i++) {
                    if ((NSInteger)job.segments.count >= kMaxSegments) return NO;
                    [job.segments addObject:[self segmentForURL:[self fillTemplate:rep.mediaTemplate rep:rep number:number time:time]
                                                          index:job.segments.count start:-1 length:-1]];
                    number++;
                    time += d;
                }
            }
            return job.segments.count > 0;
        }
        if (rep.duration > 0 && rep.timescale > 0 && period > 0) {
            NSInteger count = (NSInteger)ceil(period / (rep.duration / rep.timescale));
            if (count <= 0) return NO;
            for (NSInteger i = 0; i < count; i++) {
                if ((NSInteger)job.segments.count >= kMaxSegments) return NO;
                [job.segments addObject:[self segmentForURL:[self fillTemplate:rep.mediaTemplate rep:rep number:number time:time]
                                                      index:job.segments.count start:-1 length:-1]];
                number++;
                time += (long long)rep.duration;
            }
            return job.segments.count > 0;
        }
        return NO;   // a template with no way to know the count is not downloadable
    }

    // SegmentBase / a bare BaseURL: one resource holds the whole stream. The
    // base must have been declared, otherwise this is a manifest with no media
    // addressing and there is nothing to download.
    if (rep.hasBase) {
        if (rep.initStart >= 0) {
            job.mapSegment = [self segmentForURL:base index:-1 start:rep.initStart length:rep.initLength];
        }
        [job.segments addObject:[self segmentForURL:base index:0 start:-1 length:-1]];
        return YES;
    }

    return NO;
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
    NSMutableString *out = [template mutableCopy];
    [out replaceOccurrencesOfString:@"$RepresentationID$" withString:rep.repID ?: @""
                            options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"$Bandwidth$"
                         withString:[NSString stringWithFormat:@"%ld", (long)rep.bandwidth]
                            options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"$Time$"
                         withString:[NSString stringWithFormat:@"%lld", time]
                            options:0 range:NSMakeRange(0, out.length)];
    NSRegularExpression *numberRegex =
        [NSRegularExpression regularExpressionWithPattern:@"\\$Number(?:%0(\\d+)d)?\\$" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches =
        [numberRegex matchesInString:out options:0 range:NSMakeRange(0, out.length)];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        NSString *replacement;
        if (match.numberOfRanges > 1 && [match rangeAtIndex:1].location != NSNotFound) {
            NSInteger width = [[out substringWithRange:[match rangeAtIndex:1]] integerValue];
            replacement = [NSString stringWithFormat:@"%0*ld", (int)width, (long)number];
        } else {
            replacement = [NSString stringWithFormat:@"%ld", (long)number];
        }
        [out replaceCharactersInRange:match.range withString:replacement];
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
    if (job.paused || job.cancelled || job.finishing) return;
    while (job.inFlight < (NSUInteger)kMaxParallelSegments) {
        MVMPDSegment *next = nil;
        for (MVMPDSegment *segment in job.segments) {
            if (!segment.done && segment.retries < kMaxSegmentRetries) { next = segment; break; }
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
                MVLogWarn(@"dash: segment %ld failed (%@), retry %ld", (long)segment.index,
                          error.localizedDescription, (long)segment.retries);
            }
            [self pumpJob:job];
        });
    });
}

- (void)writeSegment:(NSData *)data index:(NSInteger)index job:(MVMPDJob *)job {
    NSString *path = [self segmentPathForJob:job index:index];
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:path atomically:NO];
}

#pragma mark - Finish

- (void)finishJob:(MVMPDJob *)job {
    if (job.finishing) return;
    job.finishing = YES;
    MVDownloadTask *task = job.task;
    task.phase = [MVLang t:@"Joining segments"];

    NSArray<MVMPDSegment *> *segments = [job.segments copy];
    MVMPDSegment *mapSegment = job.mapSegment;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *joined = [self joinedPathForJob:job];
        [fm removeItemAtPath:joined error:nil];
        [fm createFileAtPath:joined contents:nil attributes:nil];
        NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:joined];
        BOOL ok = (out != nil);
        if (mapSegment) {
            NSData *initData = [NSData dataWithContentsOfFile:[self segmentPathForJob:job index:-1]];
            if (initData.length) [out writeData:initData];
        }
        for (MVMPDSegment *segment in segments) {
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

        // A DASH stream is fragmented MP4, so the join is already an MP4 and
        // only needs the .mp4 name.
        NSString *mp4 = [joined.stringByDeletingPathExtension stringByAppendingPathExtension:@"mp4"];
        NSString *finalPath = joined;
        [fm removeItemAtPath:mp4 error:nil];
        if ([fm moveItemAtPath:joined toPath:mp4 error:nil]) finalPath = mp4;

        for (MVMPDSegment *segment in segments) {
            [fm removeItemAtPath:[self segmentPathForJob:job index:segment.index] error:nil];
        }
        [fm removeItemAtPath:[self segmentPathForJob:job index:-1] error:nil];

        NSString *directory = [MVPaths directoryForCategory:task.category];
        NSString *name = task.suggestedFilename.length ? task.suggestedFilename : finalPath.lastPathComponent;
        NSString *dest = [MVPaths uniquePathInDirectory:directory filename:name];
        NSError *moveError = nil;
        if ([fm moveItemAtPath:finalPath toPath:dest error:&moveError]) {
            finalPath = dest;
        } else {
            MVLogError(@"dash: move failed %@", moveError.localizedDescription);
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
            MVLogInfo(@"dash: finished %@ (%lld bytes) -> %@", task.title, task.totalBytes, finalPath);
            if (job.finishedBlock) job.finishedBlock(task);
        });
    });
}

#pragma mark - Failure

- (void)failJob:(MVMPDJob *)job message:(NSString *)message {
    MVDownloadTask *task = job.task;
    @synchronized (self) { [_jobs removeObjectForKey:task.identifier]; }
    MVLogError(@"dash: failed %@: %@", task.title, message);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (job.failedBlock) job.failedBlock(task, message);
    });
}

#pragma mark - Networking

/// A blocking GET on a background thread, matching the HLS engine: DASH is a
/// sequence of small requests and the parallelism lives in the segment pump.
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
        else if (http && http.statusCode >= 400) resultError = [NSError errorWithDomain:@"MVMPD"
                                                                                 code:http.statusCode
                                                                             userInfo:@{NSLocalizedDescriptionKey:
                                                                                            [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]}];
        else result = data;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)));
    if (!result && !resultError) {
        resultError = [NSError errorWithDomain:@"MVMPD" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: [MVLang t:@"Connection timed out"]}];
    }
    if (error) *error = resultError;
    return result;
}

#pragma mark - Paths

- (NSString *)segmentPathForJob:(MVMPDJob *)job index:(NSInteger)index {
    NSString *base = job.task.tempPath;
    if (!base.length) {
        NSString *directory = [MVPaths directoryForCategory:job.task.category];
        NSString *name = [MVPaths sanitizeFilename:job.task.suggestedFilename ?: job.task.url.lastPathComponent];
        if (!name.length) name = @"stream";
        base = [directory stringByAppendingPathComponent:
                [NSString stringWithFormat:@".%@.%@.dash", job.task.identifier, name]];
        job.task.tempPath = base;
    }
    return [NSString stringWithFormat:@"%@.seg%ld", base, (long)index];
}

- (NSString *)joinedPathForJob:(MVMPDJob *)job {
    return [NSString stringWithFormat:@"%@.joined", job.task.tempPath];
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
