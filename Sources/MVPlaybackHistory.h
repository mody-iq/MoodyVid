#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bounded, local-only resume positions. A changed file never inherits an old
/// position; streams and invalid/unavailable files are never recorded.
@interface MVPlaybackHistory : NSObject
+ (instancetype)shared;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (double)positionForURL:(NSURL *)url;
- (void)saveURL:(nullable NSURL *)url position:(double)position duration:(double)duration;
- (void)clearURL:(nullable NSURL *)url;
@end

NS_ASSUME_NONNULL_END
