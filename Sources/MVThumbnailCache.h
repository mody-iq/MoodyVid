#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Square video-frame thumbnails for files that are already on disk.
///
/// The download engine caches the artwork a site advertises, but a file the user
/// imported, moved or renamed has none, so the Files browser would fall back to a
/// bare glyph. This fills the gap by grabbing one frame from the video itself,
/// caching it under `MVPaths.thumbs`, and remembering it in memory so a scroll
/// does not re-decode the same file.
@interface MVThumbnailCache : NSObject

+ (instancetype)shared;

/// The thumbnail if one is already cached (memory or disk), else nil.
- (nullable UIImage *)cachedThumbnailForPath:(NSString *)path;

/// Generates a thumbnail when none is cached and calls every waiting block on
/// the main queue when it is ready. Repeated calls for one path share a single
/// generator run; a file that yields no frame is remembered as a failure so it
/// is not retried on every scroll.
- (void)thumbnailForPath:(NSString *)path completion:(void (^)(UIImage *_Nullable image))completion;

@end

NS_ASSUME_NONNULL_END
