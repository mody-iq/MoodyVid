#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Private copies of user-selected captions, keyed to a particular local file
/// and its size/modification time. Never stores a stream URL or authentication.
@interface MVSubtitleStore : NSObject
- (instancetype)initWithDirectory:(NSString *)directory;
- (nullable NSData *)dataForMediaURL:(NSURL *)url;
- (BOOL)saveData:(NSData *)data forMediaURL:(NSURL *)url;
- (void)removeForMediaURL:(nullable NSURL *)url;
@end

NS_ASSUME_NONNULL_END
