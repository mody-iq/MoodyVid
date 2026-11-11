#import "MVThumbnailCache.h"
#import "MVPaths.h"
#import <AVFoundation/AVFoundation.h>

/// Cache keys are the file path plus its size and modification time, so a file
/// replaced in place (a re-download, an edit) is regenerated rather than served
/// from a stale image.
static NSString *MVThumbKey(NSString *path) {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    long long size = [attrs[NSFileSize] longLongValue];
    NSTimeInterval mtime = [attrs[NSFileModificationDate] timeIntervalSince1970];
    return [NSString stringWithFormat:@"%@|%lld|%.0f", path, size, mtime];
}

/// The on-disk name for a path's thumbnail. The path itself is base64-encoded so
/// the name is a valid, collision-free filename whatever the folder tree holds.
static NSString *MVThumbFileName(NSString *path) {
    NSData *data = [path dataUsingEncoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:@"file-%@.jpg", [data base64EncodedStringWithOptions:0]];
}

@implementation MVThumbnailCache {
    NSCache<NSString *, UIImage *> *_images;
    NSMutableDictionary<NSString *, NSMutableArray<void (^)(UIImage *_Nullable)> *> *_waiters;
    NSMutableSet<NSString *> *_failed;
    dispatch_queue_t _queue;
}

+ (instancetype)shared {
    static MVThumbnailCache *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [MVThumbnailCache new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _images = [NSCache new];
        _images.countLimit = 200;
        _waiters = [NSMutableDictionary dictionary];
        _failed = [NSMutableSet set];
        _queue = dispatch_queue_create("com.moodyvid.thumbnails", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (UIImage *)cachedThumbnailForPath:(NSString *)path {
    if (!path.length) return nil;
    UIImage *memory = [_images objectForKey:MVThumbKey(path)];
    if (memory) return memory;
    NSString *file = [[MVPaths thumbs] stringByAppendingPathComponent:MVThumbFileName(path)];
    UIImage *disk = [UIImage imageWithContentsOfFile:file];
    if (disk) [_images setObject:disk forKey:MVThumbKey(path)];
    return disk;
}

- (void)thumbnailForPath:(NSString *)path completion:(void (^)(UIImage *_Nullable))completion {
    if (!path.length) {
        if (completion) completion(nil);
        return;
    }
    UIImage *cached = [self cachedThumbnailForPath:path];
    if (cached) {
        if (completion) completion(cached);
        return;
    }
    NSString *key = MVThumbKey(path);
    @synchronized (self) {
        if ([_failed containsObject:key]) {
            if (completion) completion(nil);
            return;
        }
        if (completion) {
            NSMutableArray *list = _waiters[key];
            if (!list) { list = [NSMutableArray array]; _waiters[key] = list; }
            [list addObject:completion];
        }
        if (_waiters[key].count > 1) return;   // a generation is already running
    }
    NSString *file = [[MVPaths thumbs] stringByAppendingPathComponent:MVThumbFileName(path)];
    dispatch_async(_queue, ^{
        UIImage *image = [self generateThumbnailForPath:path];
        if (image) [UIImageJPEGRepresentation(image, 0.82) writeToFile:file atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *waiters;
            @synchronized (self) {
                if (image) [self->_images setObject:image forKey:key];
                else [self->_failed addObject:key];
                waiters = self->_waiters[key];
                [self->_waiters removeObjectForKey:key];
            }
            for (void (^block)(UIImage *) in waiters) block(image);
        });
    });
}

/// One frame from the video, cropped square from the centre. Runs on a serial
/// background queue; AVAssetImageGenerator is safe there.
- (UIImage *)generateThumbnailForPath:(NSString *)path {
    AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:path]];
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(240, 240);
    // A second in is past the black lead-in most videos open with; a shorter
    // clip has nothing there, so fall back to the very start.
    NSError *error = nil;
    CMTime at = CMTimeMakeWithSeconds(1, 600);
    CGImageRef frame = [generator copyCGImageAtTime:at actualTime:NULL error:&error];
    if (error || !frame) {
        error = nil;
        frame = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:&error];
    }
    if (error || !frame) return nil;

    UIImage *full = [UIImage imageWithCGImage:frame];
    CGImageRelease(frame);
    CGFloat side = MIN(full.size.width, full.size.height);
    if (side <= 0) return nil;
    CGRect crop = CGRectMake((full.size.width - side) / 2.0, (full.size.height - side) / 2.0, side, side);
    CGImageRef cropped = CGImageCreateWithImageInRect(full.CGImage, crop);
    if (!cropped) return nil;
    UIImage *square = [UIImage imageWithCGImage:cropped];
    CGImageRelease(cropped);
    return square;
}

@end
