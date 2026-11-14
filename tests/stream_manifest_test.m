// Exercises the real HLS/DASH parsers without touching network or user files.
#import <Foundation/Foundation.h>
#import "MVHLSDownloader.h"
#import "MVMPDDownloader.h"
#import "MVDownloadTask.h"
#include <stdio.h>

static int failures = 0;
#define CHECK(x, message) do { if (!(x)) { fprintf(stderr, "FAIL: %s\n", message); failures++; } } while (0)

@interface MVHLSDownloader (TestInternals)
- (void)parseMediaPlaylist:(NSString *)text baseURL:(NSString *)base into:(id)job;
- (BOOL)firstVariantNeedsSeparateAudio:(NSString *)text;
- (NSString *)attribute:(NSString *)name in:(NSString *)line;
- (NSData *)dataFromHexIV:(NSString *)hex;
@end

@interface MVMPDParser : NSObject
- (instancetype)initWithURL:(NSString *)url;
- (BOOL)parse:(NSData *)data;
@property (nonatomic, readonly) NSArray *representations;
@property (nonatomic, readonly) double periodDuration;
@property (nonatomic, readonly) NSUInteger periodCount;
@property (nonatomic, readonly) BOOL isLive;
@property (nonatomic, readonly) BOOL isProtected;
@end

@interface MVMPDDownloader (TestInternals)
- (id)bestRepresentationIn:(NSArray *)representations audio:(BOOL)audio;
- (BOOL)buildSegmentsFor:(id)representation period:(double)period into:(id)job;
- (NSString *)fillTemplate:(NSString *)template rep:(id)rep number:(NSInteger)number time:(long long)time;
@end

@interface TestHLSDownloader : MVHLSDownloader
@property (nonatomic) NSUInteger keyRequests;
@end
@implementation TestHLSDownloader
- (NSData *)syncGet:(NSString *)url headers:(NSDictionary *)headers error:(NSError **)error group:(id)group {
    self.keyRequests++;
    return [NSData dataWithBytes:"0123456789abcdef" length:16];
}
@end

static id NewJob(NSString *className) {
    id job = [NSClassFromString(className) new];
    MVDownloadTask *task = [MVDownloadTask new];
    task.identifier = NSUUID.UUID.UUIDString;
    task.url = @"https://example.test/streams/manifest";
    [job setValue:task forKey:@"task"];
    return job;
}

static id ParseHLS(TestHLSDownloader *engine, NSString *playlist) {
    id job = NewJob(@"MVHLSJob");
    [engine parseMediaPlaylist:playlist baseURL:@"https://example.test/streams/list.m3u8" into:job];
    return job;
}

static void testHLS(void) {
    TestHLSDownloader *engine = [TestHLSDownloader new];
    CHECK([[engine attribute:@"URI" in:@"#EXT-X-MAP:X-URI=wrong,URI=\"right,one\""] isEqualToString:@"right,one"],
          "exact HLS attributes and quoted commas");
    CHECK([engine attribute:@"URI" in:@"#EXT-X-MAP:X-URI=wrong"] == nil, "attribute suffix is not a match");
    NSData *iv = [engine dataFromHexIV:@"0x123"];
    CHECK(iv.length == 16 && ((const unsigned char *)iv.bytes)[14] == 1 && ((const unsigned char *)iv.bytes)[15] == 0x23,
          "short hexadecimal IV is left-padded");
    CHECK(![engine dataFromHexIV:@"0x12zz"] && ![engine dataFromHexIV:@"0x"] &&
          ![engine dataFromHexIV:@"012345678901234567890123456789012"], "invalid IVs are rejected");

    NSString *ranged = @"#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:42\n#EXT-X-BYTERANGE:4@0\nclip.ts\n#EXT-X-BYTERANGE:3\nclip.ts\n#EXT-X-ENDLIST\n";
    id job = ParseHLS(engine, ranged);
    NSArray *segments = [job valueForKey:@"segments"];
    CHECK(![[job valueForKey:@"failureRequested"] boolValue] && segments.count == 2, "valid byte-range playlist");
    if (segments.count == 2) {
        CHECK([[segments[0] valueForKey:@"byteStart"] longLongValue] == 0 &&
              [[segments[0] valueForKey:@"byteLength"] longLongValue] == 4 &&
              [[segments[1] valueForKey:@"byteStart"] longLongValue] == 4 &&
              [[segments[1] valueForKey:@"sequence"] integerValue] == 43, "implicit range and media sequence");
    }
    NSArray<NSString *> *invalid = @[
        @"#EXTM3U\n#EXT-X-BYTERANGE:4\na.ts\n#EXT-X-ENDLIST\n",
        @"#EXTM3U\n#EXT-X-BYTERANGE:4@0\na.ts\n#EXT-X-BYTERANGE:3\nb.ts\n#EXT-X-ENDLIST\n",
        @"#EXTM3U\n#EXT-X-BYTERANGE:4@0\na.ts\nb.ts\n#EXT-X-BYTERANGE:3\na.ts\n#EXT-X-ENDLIST\n",
        @"#EXTM3U\n#EXT-X-BYTERANGE:4@0\na.ts\n#EXT-X-BYTERANGE:1@0\n#EXT-X-ENDLIST\n",
        @"#EXTM3U\n#EXT-X-BYTERANGE:4@9223372036854775806\na.ts\n#EXT-X-ENDLIST\n",
        @"#EXTM3U\n#EXT-X-BYTERANGE:4@0\n#EXT-X-BYTERANGE:2@0\na.ts\n#EXT-X-ENDLIST\n",
        @"#EXTM3U\na.ts\n#EXT-X-DISCONTINUITY\nb.ts\n#EXT-X-ENDLIST\n",
        @"#EXTM3U\na.ts\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-ENDLIST\n",
        @"#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\",IV=0xzz\na.ts\n#EXT-X-ENDLIST\n",
        @"#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\",KEYFORMAT=\"com.example.drm\"\na.ts\n#EXT-X-ENDLIST\n"
    ];
    for (NSString *text in invalid) {
        CHECK([[ParseHLS(engine, text) valueForKey:@"failureRequested"] boolValue], "invalid HLS is rejected");
    }
    job = ParseHLS(engine, @"#EXTM3U\n#EXT-X-MAP:URI=\"clip.mp4\",BYTERANGE=\"10@4\"\nclip.m4s\n#EXT-X-ENDLIST\n");
    id map = [job valueForKey:@"mapSegment"];
    CHECK(![[job valueForKey:@"failureRequested"] boolValue] && map &&
          [[map valueForKey:@"byteStart"] longLongValue] == 4 && [[map valueForKey:@"byteLength"] longLongValue] == 10,
          "HLS initialization range");

    engine.keyRequests = 0;
    job = ParseHLS(engine, @"#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\",IV=0x1\na.ts\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\",IV=0x2\nb.ts\n#EXT-X-ENDLIST\n");
    segments = [job valueForKey:@"segments"];
    CHECK(![[job valueForKey:@"failureRequested"] boolValue] && engine.keyRequests == 1 && segments.count == 2,
          "HLS key bytes are reused");
    if (segments.count == 2) {
        NSData *first = [[segments[0] valueForKey:@"key"] valueForKey:@"iv"];
        NSData *second = [[segments[1] valueForKey:@"key"] valueForKey:@"iv"];
        CHECK(first.length == 16 && second.length == 16 &&
              ((const unsigned char *)first.bytes)[15] == 1 && ((const unsigned char *)second.bytes)[15] == 2,
              "each key tag retains its own IV");
    }
    NSString *master = @"#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",URI=\"a.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=\"aud\"\nv.m3u8\n";
    CHECK([engine firstVariantNeedsSeparateAudio:master], "external audio is not silently omitted");
    CHECK(![engine firstVariantNeedsSeparateAudio:@"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,NOT-AUDIO=\"aud\"\nv.m3u8\n"],
          "an attribute suffix does not invent an audio group");
    CHECK([engine firstVariantNeedsSeparateAudio:@"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=\"missing\"\nv.m3u8\n"],
          "unresolved audio group is rejected");
}

static void testDASH(void) {
    NSString *xml = @"<MPD type=\"static\" mediaPresentationDuration=\"PT6S\"><Period duration=\"PT6S\">"
      "<AdaptationSet contentType=\"video\" mimeType=\"video/mp4\">"
      "<SegmentTemplate media=\"v-$RepresentationID$-$Number%03d$.m4s\" initialization=\"v-init.mp4\" duration=\"2\" timescale=\"1\" startNumber=\"4\"/>"
      "<Representation id=\"low\" bandwidth=\"100\"/><Representation id=\"high\" bandwidth=\"200\"/></AdaptationSet>"
      "<AdaptationSet contentType=\"audio\" mimeType=\"audio/mp4\"><SegmentList>"
      "<Initialization sourceURL=\"sound.mp4\" range=\"0-9\"/><SegmentURL media=\"sound.mp4\" mediaRange=\"10-19\"/>"
      "<SegmentURL media=\"sound.mp4\" mediaRange=\"20-29\"/></SegmentList>"
      "<Representation id=\"audio\" bandwidth=\"50\"/></AdaptationSet></Period></MPD>";
    MVMPDParser *parser = [[MVMPDParser alloc] initWithURL:@"https://example.test/streams/manifest.mpd"];
    CHECK([parser parse:[xml dataUsingEncoding:NSUTF8StringEncoding]], "DASH XML parses");
    CHECK(parser.periodCount == 1 && !parser.isLive && !parser.isProtected && parser.representations.count == 3,
          "DASH representations and flags");
    MVMPDDownloader *engine = [MVMPDDownloader new];
    id video = [engine bestRepresentationIn:parser.representations audio:NO];
    id audio = [engine bestRepresentationIn:parser.representations audio:YES];
    CHECK([[video valueForKey:@"repID"] isEqualToString:@"high"] && [[audio valueForKey:@"repID"] isEqualToString:@"audio"],
          "select best video and separate audio");
    id vjob = NewJob(@"MVMPDJob");
    id ajob = NewJob(@"MVMPDJob");
    CHECK([engine buildSegmentsFor:video period:parser.periodDuration into:vjob], "build inherited video template");
    NSArray *vsegments = [vjob valueForKey:@"segments"];
    CHECK(vsegments.count == 3, "video template segment count");
    if (vsegments.count) CHECK([[vsegments[0] valueForKey:@"url"] isEqualToString:@"https://example.test/streams/v-high-004.m4s"],
                               "representation and padded number in template");
    CHECK([engine buildSegmentsFor:audio period:parser.periodDuration into:ajob], "build inherited audio list");
    NSArray *asegments = [ajob valueForKey:@"segments"];
    id map = [ajob valueForKey:@"mapSegment"];
    CHECK(asegments.count == 2 && [[map valueForKey:@"byteStart"] longLongValue] == 0 &&
          [[map valueForKey:@"byteLength"] longLongValue] == 10, "audio list and initialization range");
    if (asegments.count) CHECK([[asegments[0] valueForKey:@"byteStart"] longLongValue] == 10 &&
                               [[asegments[0] valueForKey:@"byteLength"] longLongValue] == 10, "audio media range");
    CHECK([[engine fillTemplate:@"$RepresentationID$$Number$-$$.m4s" rep:video number:4 time:0]
           isEqualToString:@"https://example.test/streams/high4-$.m4s"], "adjacent placeholders and literal dollar");
    CHECK(![engine fillTemplate:@"$Number%099999999d$.m4s" rep:video number:1 time:0] &&
          ![engine fillTemplate:@"$Unknown$.m4s" rep:video number:1 time:0], "unsupported or excessive templates rejected");
    CHECK(![engine buildSegmentsFor:video period:1e300 into:NewJob(@"MVMPDJob")], "huge segment count rejected");
    NSMutableArray *timeline = [video valueForKey:@"timeline"];
    [timeline addObject:@{@"t": @0, @"d": @2, @"r": @(-1)}];
    CHECK(![engine buildSegmentsFor:video period:6 into:NewJob(@"MVMPDJob")], "negative timeline repeat rejected");

    // Period, AdaptationSet and Representation can each override part of the
    // same addressing template. BaseURL siblings are alternatives, not a chain.
    NSString *inherited = @"<MPD type=\"static\"><BaseURL>https://cdn.test/root/</BaseURL>"
      "<BaseURL>https://backup.test/</BaseURL><Period duration=\"PT4S\"><BaseURL>period/</BaseURL>"
      "<SegmentTemplate media=\"$RepresentationID$-$Number$.m4s\" initialization=\"init-$RepresentationID$.mp4\" duration=\"2\" timescale=\"1\" startNumber=\"5\"/>"
      "<AdaptationSet contentType=\"video\" mimeType=\"video/mp4\"><BaseURL>video/</BaseURL><SegmentTemplate startNumber=\"8\"/>"
      "<Representation id=\"one\" bandwidth=\"1\"><BaseURL>one/</BaseURL></Representation>"
      "<Representation id=\"two\" bandwidth=\"2\"><BaseURL>two/</BaseURL></Representation>"
      "</AdaptationSet></Period></MPD>";
    parser = [[MVMPDParser alloc] initWithURL:@"https://example.test/manifest.mpd"];
    CHECK([parser parse:[inherited dataUsingEncoding:NSUTF8StringEncoding]] && parser.representations.count == 2,
          "period-level template parses");
    video = [engine bestRepresentationIn:parser.representations audio:NO];
    vjob = NewJob(@"MVMPDJob");
    CHECK([engine buildSegmentsFor:video period:parser.periodDuration into:vjob], "period and adaptation templates inherit");
    vsegments = [vjob valueForKey:@"segments"];
    map = [vjob valueForKey:@"mapSegment"];
    CHECK(vsegments.count == 2 && [[vsegments[0] valueForKey:@"url"] isEqualToString:@"https://cdn.test/root/period/video/two/two-8.m4s"] &&
          [[map valueForKey:@"url"] isEqualToString:@"https://cdn.test/root/period/video/two/init-two.mp4"],
          "base scopes, first alternative, and template overrides are preserved");

    NSString *bare = @"<MPD><BaseURL>https://cdn.test/movie.mp4</BaseURL><Period><AdaptationSet contentType=\"video\" mimeType=\"video/mp4\">"
      "<Representation id=\"v\"/></AdaptationSet></Period></MPD>";
    parser = [[MVMPDParser alloc] initWithURL:@"https://example.test/manifest.mpd"];
    CHECK([parser parse:[bare dataUsingEncoding:NSUTF8StringEncoding]], "bare inherited BaseURL parses");
    video = [engine bestRepresentationIn:parser.representations audio:NO];
    vjob = NewJob(@"MVMPDJob");
    CHECK([engine buildSegmentsFor:video period:0 into:vjob], "MPD BaseURL counts as an inherited media URL");
    vsegments = [vjob valueForKey:@"segments"];
    CHECK(vsegments.count == 1 && [[vsegments[0] valueForKey:@"url"] isEqualToString:@"https://cdn.test/movie.mp4"],
          "inherited bare resource is fetched exactly once");

    NSString *list = @"<MPD><Period><SegmentList><Initialization sourceURL=\"init.mp4\" range=\"0-9\"/>"
      "<SegmentURL media=\"old.mp4\"/></SegmentList><AdaptationSet contentType=\"audio\" mimeType=\"audio/mp4\">"
      "<Representation id=\"a\"><SegmentList><SegmentURL media=\"new.mp4\" mediaRange=\"10-19\"/></SegmentList>"
      "</Representation></AdaptationSet></Period></MPD>";
    parser = [[MVMPDParser alloc] initWithURL:@"https://example.test/manifest.mpd"];
    CHECK([parser parse:[list dataUsingEncoding:NSUTF8StringEncoding]], "period list parses");
    audio = [engine bestRepresentationIn:parser.representations audio:YES];
    ajob = NewJob(@"MVMPDJob");
    CHECK([engine buildSegmentsFor:audio period:0 into:ajob], "representation list inherits initialization");
    asegments = [ajob valueForKey:@"segments"];
    map = [ajob valueForKey:@"mapSegment"];
    CHECK(asegments.count == 1 && [[asegments[0] valueForKey:@"url"] isEqualToString:@"https://example.test/new.mp4"] &&
          [[map valueForKey:@"url"] isEqualToString:@"https://example.test/init.mp4"] &&
          [[map valueForKey:@"byteLength"] longLongValue] == 10, "list override retains inherited initialization");
}

int main(void) {
    @autoreleasepool {
        testHLS();
        testDASH();
        if (!failures) puts("HLS and DASH manifest tests: OK");
    }
    return failures ? 1 : 0;
}
