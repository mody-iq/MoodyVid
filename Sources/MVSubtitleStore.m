#import "MVSubtitleStore.h"
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>

static const NSUInteger kMaxSubtitleBytes = 5 * 1024 * 1024;

@implementation MVSubtitleStore {
    NSString *_directory;
}

- (instancetype)initWithDirectory:(NSString *)directory {
    if ((self = [super init])) _directory = [directory copy];
    return self;
}

- (NSString *)pathForMediaURL:(NSURL *)url {
    if (!url.isFileURL || !url.path.length || !_directory.length) return nil;
    NSString *path = url.path.stringByStandardizingPath;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    NSDate *modified = attrs[NSFileModificationDate];
    NSNumber *size = attrs[NSFileSize];
    if (![attrs[NSFileType] isEqual:NSFileTypeRegular] || !modified || size.unsignedLongLongValue == 0) return nil;
    // App container UUIDs can change after restoration; relative paths remain
    // stable while unrelated external URLs remain distinct.
    NSString *home = [NSHomeDirectory().stringByStandardizingPath stringByAppendingString:@"/"];
    if ([path hasPrefix:home]) path = [path substringFromIndex:home.length];
    NSString *fingerprint = [NSString stringWithFormat:@"%@\n%@\n%.6f", path, size, modified.timeIntervalSince1970];
    NSData *bytes = [fingerprint dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes || bytes.length > UINT32_MAX) return nil;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString *name = [NSMutableString stringWithCapacity:sizeof(digest) * 2 + 4];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [name appendFormat:@"%02x", digest[i]];
    return [_directory stringByAppendingPathComponent:[name stringByAppendingString:@".sub"]];
}

- (NSData *)dataForMediaURL:(NSURL *)url {
    NSString *path = [self pathForMediaURL:url];
    if (!path) return nil;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    if (![attrs[NSFileType] isEqual:NSFileTypeRegular] || !size || size > kMaxSubtitleBytes) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:NULL];
    return data.length <= kMaxSubtitleBytes ? data : nil;
}

- (BOOL)saveData:(NSData *)data forMediaURL:(NSURL *)url {
    NSString *path = [self pathForMediaURL:url];
    if (!path || !data.length || data.length > kMaxSubtitleBytes) return NO;
    if (![NSFileManager.defaultManager createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:NULL]) return NO;
    NSDataWritingOptions options = NSDataWritingAtomic;
#if TARGET_OS_IPHONE
    options |= NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication;
#endif
    return [data writeToFile:path options:options error:NULL];
}

- (void)removeForMediaURL:(NSURL *)url {
    NSString *path = [self pathForMediaURL:url];
    if (path) [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
}
@end
