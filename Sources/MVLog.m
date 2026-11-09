#import "MVLog.h"
#import "MVPaths.h"

/// One rotated file plus the live file. Small enough that a phone can mail it,
/// large enough to hold a session's worth of download and sniffer activity.
static const unsigned long long kMaxLogBytes = 512 * 1024;

@implementation MVLog {
    dispatch_queue_t _queue;
    NSString *_path;
    NSString *_oldPath;
    NSDateFormatter *_stamp;
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

+ (void)log:(NSString *)level format:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    MVLog *log = [MVLog shared];
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                      [log->_stamp stringFromDate:NSDate.date], level, message];

    // The NSLog mirror is what makes a *system* crash log readable: those
    // capture stderr, and the shared prefix lets the owner filter one search.
    NSLog(@"MoodyVid: %@", message);

    dispatch_async(log->_queue, ^{
        [log appendLine:line];
    });
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
        // A full disk or a vanished file must never take the caller down; the
        // log is diagnostic only.
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

+ (NSArray<NSURL *> *)logFileURLs {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSString *path = [MVLog logFilePath];
    if ([fm fileExistsAtPath:path]) [urls addObject:[NSURL fileURLWithPath:path]];
    NSString *old = [path stringByAppendingPathExtension:@"1"];
    if ([fm fileExistsAtPath:old]) [urls addObject:[NSURL fileURLWithPath:old]];
    return urls;
}

+ (void)clear {
    MVLog *log = [MVLog shared];
    dispatch_async(log->_queue, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:[log path] error:nil];
        [fm removeItemAtPath:[log oldPath] error:nil];
    });
}

@end
