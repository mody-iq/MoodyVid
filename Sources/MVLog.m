#import "MVLog.h"
#import "MVPaths.h"

/// One rotated file plus the live file, bounded on disk.
static const unsigned long long kMaxLogBytes = 512 * 1024;

@implementation MVLog {
    dispatch_queue_t _queue;
    NSString *_path;
    NSString *_oldPath;
    NSDateFormatter *_stamp;
    BOOL _storageSafe;
}

+ (instancetype)shared {
    static MVLog *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVLog new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.moodyvid.log", DISPATCH_QUEUE_SERIAL);
        _stamp = [NSDateFormatter new];
        _stamp.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        _stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        // Migrate both files from older versions before accepting new writes.
        // If either cannot be scrubbed, do not append to unverified storage.
        dispatch_async(_queue, ^{
            self->_storageSafe = [self redactExistingLogs];
            if (!self->_storageSafe) NSLog(@"MoodyVid: legacy log cleanup failed; file logging disabled");
        });
    }
    return self;
}

+ (NSString *)logFilePath {
    return [[MVPaths applicationSupport] stringByAppendingPathComponent:@"MoodyVid.log"];
}

- (NSString *)path {
    if (!_path) _path = [MVLog logFilePath];
    return _path;
}

- (NSString *)oldPath {
    if (!_oldPath) _oldPath = [[self path] stringByAppendingPathExtension:@"1"];
    return _oldPath;
}

+ (NSString *)redactedText:(NSString *)text {
    if (!text.length) return @"";
    static NSArray<NSRegularExpression *> *patterns;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *expressions = @[
            // Remove complete URLs, including userinfo, path, query and fragment.
            @"(?i)\\b[a-z][a-z0-9+.-]*://[^\\s\"'<>]+",
            @"(?i)\\bmagnet(?::|%3a)(?:\\?|%3f)[^\\s\"'<>]+",
            @"(?i)\\b[a-z][a-z0-9+.-]*(?::|%3a)(?:%2f|/){2}[^\\s\"'<>]+",
            @"(?i)\\b[a-z][a-z0-9+.-]*:\\\\/\\\\/[^\\s\"'<>]+",
            // A header's unquoted value may contain spaces and semicolons;
            // redact the rest of that line rather than guess where it ends.
            @"(?i)\\b(?:cookie2?|set-cookie|authorization|proxy-authorization)[\"']?\\s*[:=]\\s*(?:\"[^\"\\r\\n]*\"|'[^'\\r\\n]*'|[^\\r\\n]*)",
            @"(?i)\\b(?:access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|client[_-]?secret|session(?:id|[_-]?token)?|password|passwd|secret|token|signature|sig)[\"']?\\s*[:=]\\s*(?:\"[^\"\\r\\n]*\"|'[^'\\r\\n]*'|[^\\s,;&}\\]]+)",
            @"(?i)\\b(?:bearer|basic)\\s+[a-z0-9+/_=.-]+"
        ];
        NSMutableArray *compiled = [NSMutableArray arrayWithCapacity:expressions.count];
        for (NSString *expression in expressions) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:expression options:0 error:nil];
            if (!regex) return; // Fail closed rather than export partly redacted text.
            [compiled addObject:regex];
        }
        patterns = [compiled copy];
    });
    if (!patterns) return @"[log message redacted]";
    NSString *clean = text;
    for (NSRegularExpression *regex in patterns) {
        clean = [regex stringByReplacingMatchesInString:clean options:0
                                                  range:NSMakeRange(0, clean.length)
                                           withTemplate:@"[redacted]"];
    }
    return clean;
}

+ (void)log:(NSString *)level format:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    message = [self redactedText:message];

    MVLog *log = [MVLog shared];
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                      [log->_stamp stringFromDate:NSDate.date], level, message];
    // Sanitize before both sinks: NSLog may appear in system crash reports too.
    NSLog(@"MoodyVid: %@", message);
    dispatch_async(log->_queue, ^{
        if (log->_storageSafe) [log appendLine:line];
    });
}

/// Runs on _queue. Non-UTF-8 legacy logs cannot be reliably scrubbed, so replace
/// their content with a notice rather than retain or export unverifiable bytes.
- (BOOL)redactExistingLogs {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *path in @[[self path], [self oldPath]]) {
        if (![fm fileExistsAtPath:path]) continue;
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&error];
        if (!data) return NO;
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *clean = text ? [MVLog redactedText:text] : @"[Unreadable legacy log removed for privacy]\n";
        if (![clean writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) return NO;
    }
    return YES;
}

- (void)appendLine:(NSString *)line {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *path = [self path];
    if (![fm fileExistsAtPath:path]) {
        [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent
      withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (NSException *e) {
        // A full disk or vanished file must not take the caller down.
    } @finally {
        [handle closeFile];
    }
    [self rotateIfNeeded];
}

- (void)rotateIfNeeded {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attrs = [fm attributesOfItemAtPath:[self path] error:nil];
    if ([attrs[NSFileSize] unsignedLongLongValue] < kMaxLogBytes) return;
    [fm removeItemAtPath:[self oldPath] error:nil];
    [fm moveItemAtPath:[self path] toPath:[self oldPath] error:nil];
}

+ (void)prepareRedactedLogsWithCompletion:(void (^)(NSArray<NSURL *> *, NSError *))completion {
    MVLog *log = self.shared;
    dispatch_async(log->_queue, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"MoodyVid-Logs-%@", NSUUID.UUID.UUIDString]] isDirectory:YES];
        NSError *error = nil;
        NSMutableArray<NSURL *> *files = [NSMutableArray array];
        if ([fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
            for (NSString *path in @[[log path], [log oldPath]]) {
                if (![fm fileExistsAtPath:path]) continue;
                NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&error];
                NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
                if (!text) {
                    if (!error) error = [NSError errorWithDomain:@"MVLog" code:1 userInfo:nil];
                    break;
                }
                NSURL *destination = [directory URLByAppendingPathComponent:path.lastPathComponent];
                if (![[self redactedText:text] writeToURL:destination atomically:YES
                                                  encoding:NSUTF8StringEncoding error:&error]) break;
                [files addObject:destination];
            }
        }
        if (error || !files.count) {
            [fm removeItemAtURL:directory error:nil];
            [files removeAllObjects];
        }
        NSArray<NSURL *> *result = [files copy];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(result, error); });
    });
}

+ (void)clear {
    MVLog *log = self.shared;
    dispatch_async(log->_queue, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *path in @[[log path], [log oldPath]]) {
            if ([fm fileExistsAtPath:path]) [fm removeItemAtPath:path error:nil];
        }
        log->_storageSafe = ![fm fileExistsAtPath:[log path]] && ![fm fileExistsAtPath:[log oldPath]];
    });
}

@end
