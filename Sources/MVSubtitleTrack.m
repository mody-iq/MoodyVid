#import "MVSubtitleTrack.h"
#include <math.h>

static const NSUInteger kSubtitleMaxBytes = 5 * 1024 * 1024;
static const NSUInteger kSubtitleMaxCues = 20000;

@interface MVSubtitleCue : NSObject
@property (nonatomic) double start;
@property (nonatomic) double end;
@property (nonatomic) double prefixMaxEnd;
@property (nonatomic, copy) NSString *text;
@end
@implementation MVSubtitleCue
@end

static double MVSubtitleTime(NSString *text) {
    NSString *normalized = [text stringByReplacingOccurrencesOfString:@"," withString:@"."];
    NSArray<NSString *> *parts = [normalized componentsSeparatedByString:@":"];
    if (parts.count != 2 && parts.count != 3) return -1;
    NSString *secondsText = parts.lastObject;
    NSArray<NSString *> *secondsParts = [secondsText componentsSeparatedByString:@"."];
    if (secondsParts.count != 2) return -1;
    double seconds = secondsParts[0].doubleValue;
    double fraction = [[@"0." stringByAppendingString:secondsParts[1]] doubleValue];
    double minutes = parts[parts.count - 2].doubleValue;
    double hours = parts.count == 3 ? parts[0].doubleValue : 0;
    if (minutes >= 60 || seconds >= 60 || hours > 999) return -1;
    return hours * 3600 + minutes * 60 + seconds + fraction;
}

static NSString *MVCleanSubtitleText(NSString *text) {
    // Captions are text, never HTML. Strip style tags and common SRT positioning
    // hints instead of rendering arbitrary markup from an untrusted file.
    NSRegularExpression *tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]{0,200}>|\\{\\\\[^}]{0,100}\\}"
        options:0 error:NULL];
    NSString *clean = [tags stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
    for (NSArray<NSString *> *pair in @[@[@"&lt;", @"<"], @[@"&gt;", @">"], @[@"&nbsp;", @" "], @[@"&amp;", @"&"]]) {
        clean = [clean stringByReplacingOccurrencesOfString:pair[0] withString:pair[1]];
    }
    clean = [clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return clean.length > 1200 ? [clean substringToIndex:1200] : clean;
}

@implementation MVSubtitleTrack {
    NSArray<MVSubtitleCue *> *_cues;
}

- (instancetype)initWithData:(NSData *)data error:(NSString **)error {
    if (!data.length || data.length > kSubtitleMaxBytes) {
        if (error) *error = @"Subtitle file is empty or larger than 5 MB.";
        return nil;
    }
    const unsigned char *bytes = data.bytes;
    BOOL utf16 = data.length >= 2 && ((bytes[0] == 0xff && bytes[1] == 0xfe) || (bytes[0] == 0xfe && bytes[1] == 0xff));
    NSString *text = [[NSString alloc] initWithData:data encoding:utf16 ? NSUTF16StringEncoding : NSUTF8StringEncoding];
    if (!text) {
        if (error) *error = @"Use a UTF-8 or UTF-16 SRT or WebVTT file.";
        return nil;
    }
    if ((self = [super init])) {
        text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
        text = [text stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
        NSRegularExpression *timing = [NSRegularExpression regularExpressionWithPattern:
            @"^\\s*((?:[0-9]{1,3}:)?[0-9]{2}:[0-9]{2}[,.][0-9]{1,3})\\s+-->\\s+((?:[0-9]{1,3}:)?[0-9]{2}:[0-9]{2}[,.][0-9]{1,3})(?:\\s.*)?$"
            options:0 error:NULL];
        NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
        NSMutableArray<MVSubtitleCue *> *cues = [NSMutableArray array];
        for (NSUInteger i = 0; i < lines.count && cues.count < kSubtitleMaxCues; i++) {
            NSString *line = lines[i];
            NSTextCheckingResult *match = [timing firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (!match) continue;
            double start = MVSubtitleTime([line substringWithRange:[match rangeAtIndex:1]]);
            double end = MVSubtitleTime([line substringWithRange:[match rangeAtIndex:2]]);
            NSMutableArray<NSString *> *body = [NSMutableArray array];
            while (i + 1 < lines.count) {
                NSString *next = lines[i + 1];
                if (![[next stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] length]) { i++; break; }
                i++;
                [body addObject:next];
            }
            NSString *caption = MVCleanSubtitleText([body componentsJoinedByString:@"\n"]);
            if (start < 0 || end <= start || !caption.length) continue;
            MVSubtitleCue *cue = [MVSubtitleCue new];
            cue.start = start; cue.end = end; cue.text = caption;
            [cues addObject:cue];
        }
        if (!cues.count) {
            if (error) *error = @"No valid subtitle cues were found.";
            return nil;
        }
        [cues sortUsingComparator:^NSComparisonResult(MVSubtitleCue *a, MVSubtitleCue *b) {
            if (a.start < b.start) return NSOrderedAscending;
            if (a.start > b.start) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        double maxEnd = 0;
        for (MVSubtitleCue *cue in cues) {
            maxEnd = MAX(maxEnd, cue.end);
            cue.prefixMaxEnd = maxEnd;
        }
        _cues = [cues copy];
    }
    return self;
}

- (NSUInteger)count { return _cues.count; }

- (NSString *)textAtSeconds:(double)seconds {
    if (!isfinite(seconds) || seconds < 0 || !_cues.count) return @"";
    // Find the last cue whose start is not after this position.
    NSUInteger low = 0, high = _cues.count;
    while (low < high) {
        NSUInteger mid = low + (high - low) / 2;
        if (_cues[mid].start <= seconds) low = mid + 1; else high = mid;
    }
    NSMutableArray<NSString *> *active = [NSMutableArray array];
    NSInteger index = (NSInteger)low - 1;
    while (index >= 0 && _cues[(NSUInteger)index].prefixMaxEnd > seconds && active.count < 4) {
        MVSubtitleCue *cue = _cues[(NSUInteger)index];
        if (cue.start <= seconds && cue.end > seconds) [active insertObject:cue.text atIndex:0];
        index--;
    }
    return [active componentsJoinedByString:@"\n"];
}
@end
