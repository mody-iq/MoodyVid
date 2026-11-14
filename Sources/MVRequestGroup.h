#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thread-safe cancellation of the individual URL tasks belonging to one
/// download. Once cancelled, even requests racing with cancellation cannot start.
@interface MVRequestGroup : NSObject
- (BOOL)startTask:(NSURLSessionTask *)task;
- (void)finishTask:(nullable NSURLSessionTask *)task;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
