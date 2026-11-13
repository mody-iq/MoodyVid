#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue when the setting or the observed default path changes.
extern NSString *const MVNetworkPolicyDidChangeNotification;

/// A shared admission rule for the native and Python queues. This does not bind
/// individual sockets to Wi-Fi and does not stop a transfer already in flight.
@interface MVNetworkPolicy : NSObject
+ (instancetype)shared;
@property (nonatomic) BOOL wifiOnly;
@property (nonatomic, readonly) BOOL allowsNewDownloads;
@end

NS_ASSUME_NONNULL_END
