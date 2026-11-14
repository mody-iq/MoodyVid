#import <Foundation/Foundation.h>
#import "MVPlaybackHistory.h"
#import "MVSubtitleTrack.h"
#import "MVSubtitleStore.h"
#include <math.h>

static int failures = 0;
#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expr); failures++; } } while (0)

static void subtitleTests(void) {
    NSString *input = @"WEBVTT\n\n1\n00:00:01.000 --> 00:00:04.000 align:center\n<i>Hello</i> &amp; world\n\n"
                      "2\n00:00:02.500 --> 00:00:03.500\nمرحبا\n\n"
                      "3\n00:00:05,000 --> 00:00:07,000\nLast line\n";
    NSString *error = nil;
    MVSubtitleTrack *track = [[MVSubtitleTrack alloc] initWithData:[input dataUsingEncoding:NSUTF8StringEncoding] error:&error];
    CHECK(track != nil && error == nil && track.count == 3);
    CHECK([[track textAtSeconds:0] isEqualToString:@""]);
    CHECK([[track textAtSeconds:1.2] isEqualToString:@"Hello & world"]);
    CHECK([[track textAtSeconds:2.5] isEqualToString:@"Hello & world\nمرحبا"]);
    CHECK([[track textAtSeconds:3.5] isEqualToString:@"Hello & world"]);
    CHECK([[track textAtSeconds:4] isEqualToString:@""]);
    CHECK([[track textAtSeconds:6] isEqualToString:@"Last line"]);
    CHECK([[track textAtSeconds:NAN] isEqualToString:@""]);
    CHECK([[MVSubtitleTrack alloc] initWithData:[NSData data] error:&error] == nil);
    CHECK([[MVSubtitleTrack alloc] initWithData:[NSMutableData dataWithLength:5 * 1024 * 1024 + 1] error:&error] == nil);
    NSData *utf16 = [@"1\n00:00:01,000 --> 00:00:02,000\nمرحبا\n" dataUsingEncoding:NSUTF16StringEncoding];
    track = [[MVSubtitleTrack alloc] initWithData:utf16 error:NULL];
    CHECK([[track textAtSeconds:1.5] isEqualToString:@"مرحبا"]);
    NSData *invalid = [@"1\n00:99:01,000 --> 00:99:02,000\ninvalid\n" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK([[MVSubtitleTrack alloc] initWithData:invalid error:&error] == nil);
}

static void historyTests(void) {
    NSString *suite = [@"com.moodyvid.test.playback." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    MVPlaybackHistory *history = [[MVPlaybackHistory alloc] initWithDefaults:defaults];
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:suite];
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL]);
    NSString *path = [dir stringByAppendingPathComponent:@"video.mp4"];
    CHECK([[NSData dataWithBytes:"first" length:5] writeToFile:path atomically:YES]);
    NSURL *url = [NSURL fileURLWithPath:path];
    MVSubtitleStore *subtitleStore = [[MVSubtitleStore alloc] initWithDirectory:[dir stringByAppendingPathComponent:@"subtitles"]];
    NSData *subtitle = [@"00:00:01,000 --> 00:00:03,000\nHello" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK([subtitleStore saveData:subtitle forMediaURL:url]);
    CHECK([[subtitleStore dataForMediaURL:url] isEqualToData:subtitle]);
    NSURL *stream = [NSURL URLWithString:@"https://example.test/stream?token=secret"];
    CHECK(![subtitleStore saveData:subtitle forMediaURL:stream] && ![subtitleStore dataForMediaURL:stream]);
    CHECK(![subtitleStore saveData:[NSMutableData dataWithLength:5 * 1024 * 1024 + 1] forMediaURL:url]);

    [history saveURL:url position:30 duration:120];
    CHECK([history positionForURL:url] == 30);
    [history saveURL:url position:119 duration:120];
    CHECK([history positionForURL:url] == 0); // finished videos start over
    [history saveURL:url position:1 duration:120];
    CHECK([history positionForURL:url] == 0);
    [history saveURL:url position:40 duration:120];
    CHECK([history positionForURL:url] == 40);
    [history saveURL:url position:NAN duration:120];
    CHECK([history positionForURL:url] == 40); // invalid state must not erase a good one
    CHECK([[NSData dataWithBytes:"different" length:9] writeToFile:path atomically:YES]);
    CHECK([history positionForURL:url] == 0); // same name, different file
    CHECK(![subtitleStore dataForMediaURL:url]); // captions cannot follow a replacement file
    CHECK([subtitleStore saveData:subtitle forMediaURL:url]);
    [subtitleStore removeForMediaURL:url];
    CHECK(![subtitleStore dataForMediaURL:url]);
    NSURL *remote = [NSURL URLWithString:@"https://example.test/video.mp4?token=secret"];
    [history saveURL:remote position:30 duration:120];
    CHECK([history positionForURL:remote] == 0);
    for (NSUInteger i = 0; i < 205; i++) {
        NSString *item = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu.mp4", (unsigned long)i]];
        CHECK([[NSData dataWithBytes:"x" length:1] writeToFile:item atomically:YES]);
        [history saveURL:[NSURL fileURLWithPath:item] position:10 duration:100];
    }
    CHECK([[defaults dictionaryForKey:@"MVPlaybackPositionsV1"] count] == 200);
    [defaults removePersistentDomainForName:suite];
    [NSFileManager.defaultManager removeItemAtPath:dir error:NULL];
}

int main(void) {
    @autoreleasepool {
        subtitleTests();
        historyTests();
        if (failures) return 1;
        puts("ALL PLAYER MODEL TESTS PASSED");
    }
    return 0;
}
